import Testing
import Foundation
@testable import CallBrainAppCore
@testable import CallBrainCore

/// T2 — the Google Meet caption transcript: the structured, speaker-NAMED turns the recording path
/// harvests from the extension bridge and the import pipeline prefers over WhisperKit.
@Suite("Meet caption transcript (T2)")
struct MeetCaptionTranscriptTests {

    private func turn(_ speaker: String, _ text: String) -> CaptionTurn {
        CaptionTurn(speaker: speaker, text: text)
    }

    @Test("parsed() keeps real speaker names, order, and marks no-timestamp confidence")
    func testParsedNamedTurns() {
        let caps = MeetCaptionTranscript(title: "Sync", date: "2026-07-08", turns: [
            turn("Alex", "let's ship it"),
            turn("Maya", "I'll take the API"),
            turn("Alex", "great"),
        ])
        let p = caps.parsed()
        #expect(p.source == .gmeetCaptions)
        #expect(p.title == "Sync")
        #expect(p.date == "2026-07-08")
        #expect(p.speakers == ["Alex", "Maya"])                 // distinct, first-seen order
        #expect(p.utterances.map(\.speakerRaw) == ["Alex", "Maya", "Alex"])
        #expect(p.utterances.map(\.text) == ["let's ship it", "I'll take the API", "great"])
        #expect(p.utterances.map(\.seq) == [0, 1, 2])           // order preserved
        #expect(p.utterances.allSatisfy { $0.tsConfidence == .none })   // captions carry no timecodes
        #expect(p.utterances.allSatisfy { $0.speakerConfidence == 1.0 }) // named → high confidence
    }

    @Test("parsed() drops blank speaker/text turns")
    func testParsedSkipsBlank() {
        let caps = MeetCaptionTranscript(turns: [
            turn("Alex", "real"),
            turn("   ", "no speaker"),
            turn("Maya", "   "),
            turn("", ""),
        ])
        let p = caps.parsed()
        #expect(p.utterances.count == 1)
        #expect(p.utterances.first?.speakerRaw == "Alex")
        #expect(p.utterances.first?.seq == 0)
    }

    @Test("hasContent is false when every turn is blank")
    func testHasContent() {
        #expect(MeetCaptionTranscript(turns: [turn("Alex", "hi")]).hasContent)
        #expect(!MeetCaptionTranscript(turns: [turn(" ", " "), turn("", "")]).hasContent)
        #expect(!MeetCaptionTranscript(turns: []).hasContent)
    }

    @Test("sidecar write→read round-trips and sits next to the WAV")
    func testSidecarRoundTrip() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cbcaptions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let wav = dir.appendingPathComponent("Morning Sync — 2026-07-08.wav")
        let sidecar = MeetCaptionTranscript.sidecarURL(forRecording: wav)
        #expect(sidecar.lastPathComponent == "Morning Sync — 2026-07-08.cbcaptions")
        #expect(sidecar.deletingLastPathComponent() == wav.deletingLastPathComponent())

        let caps = MeetCaptionTranscript(title: "Morning Sync", date: "2026-07-08",
                                         turns: [turn("Alex", "one"), turn("Maya", "two")])
        try caps.write(to: sidecar)
        let back = MeetCaptionTranscript.read(from: sidecar)
        #expect(back == caps)
    }

    @Test("read() returns nil for a missing, empty, or content-less sidecar (→ WhisperKit fallback)")
    func testReadFallback() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cbcaptions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let missing = dir.appendingPathComponent("nope.captions.json")
        #expect(MeetCaptionTranscript.read(from: missing) == nil)      // no file

        let garbage = dir.appendingPathComponent("garbage.captions.json")
        try Data("not json".utf8).write(to: garbage)
        #expect(MeetCaptionTranscript.read(from: garbage) == nil)      // corrupt

        let blank = dir.appendingPathComponent("blank.captions.json")
        try MeetCaptionTranscript(turns: [turn(" ", " ")]).write(to: blank)
        #expect(MeetCaptionTranscript.read(from: blank) == nil)        // no usable turns
    }
}
