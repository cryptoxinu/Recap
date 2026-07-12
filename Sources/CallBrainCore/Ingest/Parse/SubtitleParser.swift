import Foundation

/// Parses SRT and WebVTT subtitle/caption files into the CTM.
///
/// This is deterministic by design: cue timing is source-stamped (`.exact`), VTT `<v Speaker>` tags become
/// explicit speakers, and untagged captions stay under the generic `"Unknown"` label with no confidence.
public enum SubtitleParser {

    public static func parse(_ text: String) throws -> ParsedTranscript {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ParseError.empty
        }

        let cues = blocks(in: normalized).compactMap(cue(from:))
        guard !cues.isEmpty else {
            throw ParseError.unrecognizedStructure("Subtitle: no SRT/VTT cues recognized")
        }

        let utterances = merge(cues)
        let speakers = orderedUnique(utterances.map(\.speakerRaw))
        let duration = utterances.map(\.tEnd).max().map { Int($0.rounded(.up)) }

        return ParsedTranscript(title: nil, date: nil, startedAt: nil, durationSeconds: duration,
                                source: .srtVtt, speakers: speakers, utterances: utterances)
    }

    // MARK: - Cue parsing

    private struct Cue {
        let speaker: String?
        let start: Double
        let end: Double
        let text: String
    }

    private struct Timing {
        let start: Double
        let end: Double
    }

    private static func blocks(in text: String) -> [[String]] {
        var out: [[String]] = []
        var current: [String] = []
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !current.isEmpty {
                    out.append(current)
                    current = []
                }
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    private static func cue(from block: [String]) -> Cue? {
        guard let timingIndex = block.firstIndex(where: { timing(in: $0) != nil }),
              let t = timing(in: block[timingIndex]) else { return nil }
        let textLines = Array(block.dropFirst(timingIndex + 1))
        let raw = textLines.joined(separator: " ")
        let body = cleanCueText(raw)
        guard !body.isEmpty else { return nil }
        return Cue(speaker: voiceSpeaker(in: raw), start: t.start, end: max(t.start, t.end), text: body)
    }

    private static func merge(_ cues: [Cue]) -> [ParsedUtterance] {
        var utterances: [ParsedUtterance] = []
        for cue in cues {
            let speaker = cue.speaker ?? SpeakerAligner.unattributed
            if cue.speaker != nil, let last = utterances.last, last.speakerRaw == speaker {
                let merged = ParsedUtterance(
                    seq: last.seq,
                    speakerRaw: last.speakerRaw,
                    speakerConfidence: last.speakerConfidence,
                    tStart: last.tStart,
                    tEnd: max(last.tEnd, cue.end),
                    text: [last.text, cue.text].joined(separator: " "),
                    isInferredSpeaker: last.isInferredSpeaker,
                    tsConfidence: last.tsConfidence)
                utterances = Array(utterances.dropLast()) + [merged]
            } else {
                utterances.append(ParsedUtterance(
                    seq: utterances.count,
                    speakerRaw: speaker,
                    speakerConfidence: cue.speaker == nil ? nil : 1.0,
                    tStart: cue.start,
                    tEnd: cue.end,
                    text: cue.text,
                    isInferredSpeaker: cue.speaker == nil,
                    tsConfidence: .exact))
            }
        }
        return utterances
    }

    // MARK: - Timing

    private static let timingRE = try! NSRegularExpression(
        pattern: #"^\s*((?:\d{1,2}:)?\d{1,2}:\d{2}(?:[,.]\d{1,3})?)\s*-->\s*((?:\d{1,2}:)?\d{1,2}:\d{2}(?:[,.]\d{1,3})?)(?:\s+.*)?$"#)

    private static func timing(in line: String) -> Timing? {
        let ns = line as NSString
        guard let m = timingRE.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
              let start = seconds(fromSubtitleTime: ns.substring(with: m.range(at: 1))),
              let end = seconds(fromSubtitleTime: ns.substring(with: m.range(at: 2))) else { return nil }
        return Timing(start: start, end: end)
    }

    /// SRT/VTT-local time parsing: `HH:MM:SS,mmm`, `HH:MM:SS.mmm`, and `MM:SS.mmm`.
    private static func seconds(fromSubtitleTime raw: String) -> Double? {
        let parts = raw.trimmingCharacters(in: .whitespaces).split(separator: ":").map(String.init)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        let leading = parts.dropLast().compactMap(Int.init)
        guard leading.count == parts.count - 1 else { return nil }

        let last = parts[parts.count - 1]
        let splitIndex = last.firstIndex(where: { $0 == "." || $0 == "," })
        let secondsText = splitIndex.map { String(last[..<$0]) } ?? last
        guard let seconds = Int(secondsText), (0...59).contains(seconds) else { return nil }

        let fraction: Double
        if let splitIndex {
            let digits = String(last[last.index(after: splitIndex)...])
            guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
            let millis = String(digits.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0)
            fraction = Double(Int(millis) ?? 0) / 1000.0
        } else {
            fraction = 0
        }

        if parts.count == 2 {
            return Double(leading[0] * 60 + seconds) + fraction
        }
        guard (0...59).contains(leading[1]) else { return nil }
        return Double(leading[0] * 3600 + leading[1] * 60 + seconds) + fraction
    }

    // MARK: - Text cleanup

    private static let voiceRE = try! NSRegularExpression(pattern: #"<v(?:\.[^>\s]+)?\s+([^>]+)>"#)
    private static let tagRE = try! NSRegularExpression(pattern: #"<[^>]+>"#)

    private static func voiceSpeaker(in raw: String) -> String? {
        let ns = raw as NSString
        guard let m = voiceRE.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        let speaker = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
        return speaker.isEmpty ? nil : speaker
    }

    private static func cleanCueText(_ raw: String) -> String {
        let full = NSRange(location: 0, length: (raw as NSString).length)
        var text = voiceRE.stringByReplacingMatches(in: raw, range: full, withTemplate: "")
        let tagRange = NSRange(location: 0, length: (text as NSString).length)
        text = tagRE.stringByReplacingMatches(in: text, range: tagRange, withTemplate: "")
        text = decodeBasicEntities(text)
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeBasicEntities(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func orderedUnique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for value in values where seen.insert(value).inserted {
            out.append(value)
        }
        return out
    }
}
