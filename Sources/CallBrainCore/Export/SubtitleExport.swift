import Foundation

/// Subtitle export (W5, Recordly-inspired — algorithm reimplemented, no AGPL source copied).
///
/// The stored transcript is TURN-level, not word-level (`Store.utterances` gives one `tStart` per turn
/// and NO end time), so the Recordly word-gap heuristic can't run on words. Instead we treat each turn as
/// a cue whose end is derived from the next turn's start (or a text-length estimate for the last turn),
/// then apply a readable-line splitter so long turns wrap into ≤`maxLineChars`, ≤2-line captions.
///
/// Pure + deterministic: no I/O, no Store, no clock — assembled off-main, unit-testable against exact
/// SRT/VTT strings.
public enum SubtitleExport {

    /// Subtitle container format. SRT uses `,` for the millisecond separator; WebVTT uses `.` and a
    /// `WEBVTT` header.
    public enum SubtitleFormat: Sendable, Equatable {
        case srt
        case vtt
    }

    /// A single turn to caption. Decoupled from `Store.UtteranceRow` so the exporter stays pure and easy
    /// to test — the app maps rows (resolving a missing `tStart` by carrying the previous turn's start
    /// forward) into this DTO at the call site.
    public struct SubtitleUtterance: Sendable, Equatable {
        /// Cue start, in seconds from the recording's t=0.
        public let start: Double
        /// Speaker label, prefixed on the first caption line when it changes between cues.
        public let speaker: String?
        public let text: String
        public init(start: Double, speaker: String?, text: String) {
            self.start = start
            self.speaker = speaker
            self.text = text
        }
    }

    // MARK: - Public API

    /// Render turn-level utterances as a `.srt` or `.vtt` document.
    ///
    /// - Cue start = the turn's `start`.
    /// - Cue end = `min(nextStart, start + maxCueSeconds)`, floored at `start + minCueSeconds`, and never
    ///   past the next turn's start (no overlap). For the last turn (no next start) the end is a
    ///   text-length estimate (~0.35s/word), floored at `minCueSeconds` and capped at `maxCueSeconds`.
    /// - Each cue's text is sanitized (control chars stripped, whitespace collapsed) then wrapped at word
    ///   boundaries into ≤`maxLineChars` lines (≤2 for normal-length turns; longer turns keep all content
    ///   and wrap into more lines rather than dropping any), preferring clause-punctuation break points.
    /// - Cues with empty text after sanitizing are skipped, but still bound the previous cue's end.
    public static func subtitles(from utterances: [SubtitleUtterance],
                                 format: SubtitleFormat,
                                 maxLineChars: Int = 42,
                                 maxCueSeconds: Double = 6,
                                 minCueSeconds: Double = 1.2) -> String {
        let cues = buildCues(utterances,
                             maxLineChars: maxLineChars,
                             maxCueSeconds: maxCueSeconds,
                             minCueSeconds: minCueSeconds)
        return render(cues, format: format)
    }

    // MARK: - Cue model

    struct Cue: Equatable {
        let start: Double
        let end: Double
        let lines: [String]
    }

    // MARK: - Cue building

    static func buildCues(_ utterances: [SubtitleUtterance],
                          maxLineChars: Int,
                          maxCueSeconds: Double,
                          minCueSeconds: Double) -> [Cue] {
        let maxLine = max(1, maxLineChars)
        let minCue = max(0.001, min(minCueSeconds, maxCueSeconds))
        let maxCue = max(minCue, maxCueSeconds)

        var cues: [Cue] = []
        var lastSpeaker: String?

        for (i, u) in utterances.enumerated() {
            let cleaned = sanitize(u.text)
            // Empty turns emit no cue but their position still bounds the previous cue's end.
            guard !cleaned.isEmpty else { continue }

            let start = max(0, u.start)
            // Boundary = the NEXT turn's start (whether or not that turn has text), i.e. when this
            // speaker stopped. nil only for the genuinely last turn in the call.
            let nextStart = (i + 1 < utterances.count) ? max(0, utterances[i + 1].start) : nil

            let end = cueEnd(start: start,
                             nextStart: nextStart,
                             wordCount: wordCount(cleaned),
                             minCue: minCue,
                             maxCue: maxCue)

            // Prefix the speaker on the first line only when it changed from the previous emitted cue.
            let speaker = u.speaker?.trimmingCharacters(in: .whitespacesAndNewlines)
            let changed = (speaker?.isEmpty == false) && speaker != lastSpeaker
            let body = changed ? "\(speaker!): \(cleaned)" : cleaned
            if let s = speaker, !s.isEmpty { lastSpeaker = s }

            cues.append(Cue(start: start, end: end, lines: wrap(body, max: maxLine)))
        }
        return cues
    }

    /// End time for one cue. No-overlap is the hard invariant: when the next turn begins sooner than
    /// `start + minCue`, the cue is shortened to the next start rather than overlapping it (a valid
    /// subtitle can't have overlapping cues). `minCue` therefore only fully applies when there is room —
    /// most visibly on the last cue (its estimate is floored to `minCue`).
    static func cueEnd(start: Double, nextStart: Double?, wordCount: Int,
                       minCue: Double, maxCue: Double) -> Double {
        if let next = nextStart {
            let raw = min(next, start + maxCue)
            let floored = max(raw, start + minCue)
            // Never past the next start; keep strictly positive even for degenerate/duplicate stamps.
            return min(floored, max(next, start + 0.001))
        }
        // Last cue: estimate from word count (~0.35s/word), floored at minCue, capped at maxCue.
        let estimate = min(maxCue, max(minCue, Double(wordCount) * 0.35))
        return start + estimate
    }

    // MARK: - Rendering

    static func render(_ cues: [Cue], format: SubtitleFormat) -> String {
        var out = format == .vtt ? "WEBVTT\n\n" : ""
        for (i, cue) in cues.enumerated() {
            out += "\(i + 1)\n"
            out += "\(timestamp(cue.start, format: format)) --> \(timestamp(cue.end, format: format))\n"
            out += cue.lines.joined(separator: "\n")
            out += "\n"
            if i < cues.count - 1 { out += "\n" }   // blank line between cues
        }
        return out
    }

    /// `HH:MM:SS,mmm` (SRT) / `HH:MM:SS.mmm` (VTT). Negative times clamp to 0; milliseconds round to
    /// nearest (ties away from zero) and carry correctly (e.g. 3599.9999 → `01:00:00`).
    static func timestamp(_ seconds: Double, format: SubtitleFormat) -> String {
        let totalMillis = Int((max(0, seconds) * 1000).rounded())
        let ms = totalMillis % 1000
        let totalSec = totalMillis / 1000
        let s = totalSec % 60
        let m = (totalSec / 60) % 60
        let h = totalSec / 3600
        let sep = format == .srt ? "," : "."
        return String(format: "%02d:%02d:%02d%@%03d", h, m, s, sep, ms)
    }

    // MARK: - Text hygiene + wrapping

    /// Strip control characters (so a caption can't inject a blank line and split the cue) and collapse
    /// all whitespace runs to a single space. Newlines/tabs become spaces; other C0/C1 controls drop.
    static func sanitize(_ s: String) -> String {
        var out = ""
        out.unicodeScalars.reserveCapacity(s.unicodeScalars.count)
        for u in s.unicodeScalars {
            if u == "\n" || u == "\r" || u == "\t" {
                out.unicodeScalars.append(" ")
            } else if u.properties.generalCategory == .control || u.properties.generalCategory == .format {
                continue   // drop remaining control/format chars (e.g. NUL, bidi marks)
            } else {
                out.unicodeScalars.append(u)
            }
        }
        let collapsed = out
            .replacingOccurrences(of: " +", with: " ", options: .regularExpression)
            // WebVTT forbids "-->" anywhere in a cue payload — a conforming parser treats it as a cue
            // boundary and DROPS the caption; SRT's cue timing uses it too. Neutralize it to a real arrow.
            .replacingOccurrences(of: "-->", with: "→")
        return collapsed.trimmingCharacters(in: .whitespaces)
    }

    static func wordCount(_ s: String) -> Int {
        s.split(whereSeparator: { $0 == " " }).count
    }

    /// Word-boundary wrap into lines ≤ `max`. Never splits a word (a single over-long word is kept whole
    /// on its own line). Normal-length text yields ≤2 lines; when it can't fit in two lines all content is
    /// preserved across more lines. For the common 2-line case the break prefers a clause-punctuation
    /// boundary (`. ? ! , ; :`) so lines read as phrases.
    static func wrap(_ text: String, max: Int) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        if trimmed.count <= max { return [trimmed] }

        let words = trimmed.split(separator: " ").map(String.init)
        let greedy = greedyWrap(words, max: max)
        if greedy.count == 2, let clause = clausePreferredTwoLine(words, max: max) {
            return clause
        }
        return greedy
    }

    static func greedyWrap(_ words: [String], max: Int) -> [String] {
        var lines: [String] = []
        var cur = ""
        for word in words {
            let candidate = cur.isEmpty ? word : cur + " " + word
            if candidate.count <= max {
                cur = candidate
            } else if cur.isEmpty {
                lines.append(word)   // single word longer than max — keep whole, never split mid-word
            } else {
                lines.append(cur)
                cur = word
            }
        }
        if !cur.isEmpty { lines.append(cur) }
        return lines
    }

    /// For a text that greedily fits in exactly two lines, pick the LATEST split where both lines are
    /// ≤ `max` AND the first line ends at clause punctuation — so captions break at phrase boundaries.
    /// Returns nil when no such clause split exists (caller keeps the greedy split), so this never
    /// increases the line count or exceeds `max`.
    static func clausePreferredTwoLine(_ words: [String], max: Int) -> [String]? {
        let clausePunct: Set<Character> = [".", "?", "!", ",", ";", ":"]
        var best: Int?
        for k in 1..<words.count {
            let line1 = words[0..<k].joined(separator: " ")
            let line2 = words[k...].joined(separator: " ")
            guard line1.count <= max, line2.count <= max else { continue }
            if let last = line1.last, clausePunct.contains(last) { best = k }
        }
        guard let k = best else { return nil }
        return [words[0..<k].joined(separator: " "), words[k...].joined(separator: " ")]
    }
}
