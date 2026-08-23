import Testing
import Foundation
@testable import CallBrainCore

/// W5 — subtitle export. Turn-level utterances → readable `.srt`/`.vtt` cues. Exact-string asserts for
/// the format (timestamps, separators, indices, blank lines); numeric asserts (via internal `buildCues`)
/// for the timing invariants (no-overlap, minCue floor, last-cue estimate).
@Suite("Subtitle export (.srt/.vtt)")
struct SubtitleExportTests {
    typealias U = SubtitleExport.SubtitleUtterance

    // A stable 3-turn fixture with known starts and changing speakers.
    private let three: [U] = [
        U(start: 1.0, speaker: "Alex", text: "Hello there"),
        U(start: 3.0, speaker: "Sam",  text: "Hi Alex"),
        U(start: 5.0, speaker: "Alex", text: "How are you"),
    ]

    @Test("SRT is byte-exact: indices, comma-millis, blank separators, contiguous cue ends")
    func srtExact() {
        let srt = SubtitleExport.subtitles(from: three, format: .srt)
        let expected =
            "1\n00:00:01,000 --> 00:00:03,000\nAlex: Hello there\n\n" +
            "2\n00:00:03,000 --> 00:00:05,000\nSam: Hi Alex\n\n" +
            "3\n00:00:05,000 --> 00:00:06,200\nAlex: How are you\n"
        #expect(srt == expected)
        // Cue N end == cue N+1 start (no gap, no overlap) for interior cues.
        let cues = SubtitleExport.buildCues(three, maxLineChars: 42, maxCueSeconds: 6, minCueSeconds: 1.2)
        #expect(cues.count == 3)
        #expect(abs(cues[0].end - cues[1].start) < 1e-9)
        #expect(abs(cues[1].end - cues[2].start) < 1e-9)
        // Last cue: text-length estimate (3 words * 0.35 = 1.05) floored to minCue 1.2.
        #expect(abs(cues[2].end - 6.2) < 1e-9)
    }

    @Test("VTT has the WEBVTT header and dot-millis (no commas in timings)")
    func vttExact() {
        let vtt = SubtitleExport.subtitles(from: three, format: .vtt)
        let expected =
            "WEBVTT\n\n" +
            "1\n00:00:01.000 --> 00:00:03.000\nAlex: Hello there\n\n" +
            "2\n00:00:03.000 --> 00:00:05.000\nSam: Hi Alex\n\n" +
            "3\n00:00:05.000 --> 00:00:06.200\nAlex: How are you\n"
        #expect(vtt == expected)
        #expect(vtt.hasPrefix("WEBVTT\n\n"))
        // No SRT-style comma millisecond separators anywhere in a VTT timing line.
        #expect(!vtt.contains(",00") && !vtt.contains("00,"))
    }

    @Test("Timestamp formatting: zero-pad, ms rounding, and minute/hour carry")
    func timestampEdges() {
        #expect(SubtitleExport.timestamp(0, format: .srt) == "00:00:00,000")
        #expect(SubtitleExport.timestamp(-5, format: .srt) == "00:00:00,000")   // negative clamps to 0
        #expect(SubtitleExport.timestamp(6.2, format: .srt) == "00:00:06,200")
        #expect(SubtitleExport.timestamp(6.2, format: .vtt) == "00:00:06.200")
        #expect(SubtitleExport.timestamp(59.9996, format: .srt) == "00:01:00,000")   // ms carry → minute
        #expect(SubtitleExport.timestamp(3599.9999, format: .vtt) == "01:00:00.000") // carry → hour
        #expect(SubtitleExport.timestamp(3661.5, format: .srt) == "01:01:01,500")
    }

    @Test("Wrapping: word boundaries only, ≤ maxLineChars, ≤2 lines, content preserved")
    func wrapInvariants() {
        let text = "the quick brown fox jumps over the lazy dog and then keeps running fast"
        let lines = SubtitleExport.wrap(text, max: 42)
        #expect(lines.count == 2)
        for line in lines { #expect(line.count <= 42) }
        // No mid-word split + nothing dropped: re-joining the lines reproduces the original words.
        #expect(lines.joined(separator: " ") == text)
    }

    @Test("Wrapping prefers a clause-punctuation break point")
    func wrapClausePreference() {
        let text = "hello there my friend, welcome to the show tonight everyone"
        let lines = SubtitleExport.wrap(text, max: 42)
        #expect(lines.count == 2)
        #expect(lines[0] == "hello there my friend,")            // break lands right after the comma
        #expect(lines[0].hasSuffix(","))
        for line in lines { #expect(line.count <= 42) }
        #expect(lines.joined(separator: " ") == text)
    }

    @Test("A single over-long word is kept whole, never split mid-word")
    func wrapLongWord() {
        let word = String(repeating: "x", count: 60)
        let lines = SubtitleExport.wrap(word, max: 42)
        #expect(lines == [word])
    }

    @Test("No-overlap wins over minCue when the next turn starts sooner than minCue")
    func noOverlapInvariant() {
        let close: [U] = [
            U(start: 10.0, speaker: "A", text: "quick"),
            U(start: 10.3, speaker: "A", text: "again"),
        ]
        let cues = SubtitleExport.buildCues(close, maxLineChars: 42, maxCueSeconds: 6, minCueSeconds: 1.2)
        #expect(cues.count == 2)
        #expect(cues[0].end <= cues[1].start + 1e-9)          // never overlaps the next cue
        #expect(abs(cues[0].end - 10.3) < 1e-9)               // shortened to the next start, not minCue
    }

    @Test("Last-cue estimate: minCue floor, per-word growth, and maxCue cap")
    func lastCueEstimate() {
        // 1 short word → 0.35 floored to minCue 1.2.
        let one = SubtitleExport.buildCues([U(start: 0, speaker: nil, text: "Hi")],
                                           maxLineChars: 42, maxCueSeconds: 6, minCueSeconds: 1.2)
        #expect(abs(one[0].end - 1.2) < 1e-9)
        // 10 words → 10 * 0.35 = 3.5 (between floor and cap).
        let ten = SubtitleExport.buildCues([U(start: 0, speaker: nil, text: "a b c d e f g h i j")],
                                           maxLineChars: 42, maxCueSeconds: 6, minCueSeconds: 1.2)
        #expect(abs(ten[0].end - 3.5) < 1e-9)
        // 30 words → 10.5 capped to maxCue 6.
        let many = SubtitleExport.buildCues([U(start: 0, speaker: nil,
                                               text: Array(repeating: "w", count: 30).joined(separator: " "))],
                                            maxLineChars: 42, maxCueSeconds: 6, minCueSeconds: 1.2)
        #expect(abs(many[0].end - 6.0) < 1e-9)
    }

    @Test("Control chars / newlines are stripped so a caption can't corrupt cue structure")
    func sanitization() {
        // NUL dropped, \n & \t & \r → space, U+202A (format char) dropped, runs collapsed.
        let dirty = "Hello\u{0000}\nworld\t\u{202A}test\r\rmore"
        #expect(SubtitleExport.sanitize(dirty) == "Hello world test more")
        // End-to-end: an utterance carrying embedded newlines must render as ONE cue with no blank line
        // inside its body (a blank line would prematurely terminate the cue block).
        let srt = SubtitleExport.subtitles(from: [U(start: 0, speaker: nil, text: "line one\n\nline two")],
                                           format: .srt)
        #expect(srt == "1\n00:00:00,000 --> 00:00:01,400\nline one line two\n")
        #expect(!srt.contains("\n\n\n"))
    }

    @Test("Whitespace-only turns emit no cue but still bound the previous cue's end")
    func emptyTurnBoundsButOmits() {
        let rows: [U] = [
            U(start: 1.0, speaker: "A", text: "real one"),
            U(start: 2.0, speaker: "A", text: "   \n\t  "),   // empty after sanitizing
            U(start: 3.0, speaker: "A", text: "real two"),
        ]
        let cues = SubtitleExport.buildCues(rows, maxLineChars: 42, maxCueSeconds: 6, minCueSeconds: 1.2)
        #expect(cues.count == 2)                               // the blank turn is skipped
        #expect(abs(cues[0].end - 2.0) < 1e-9)                // but its start still ends cue 0 (silence gap)
        #expect(abs(cues[1].start - 3.0) < 1e-9)
    }

    @Test("Empty input yields empty output (nothing to disable-guard around)")
    func emptyInput() {
        #expect(SubtitleExport.subtitles(from: [], format: .srt) == "")
        #expect(SubtitleExport.subtitles(from: [], format: .vtt) == "WEBVTT\n\n")
    }
}
