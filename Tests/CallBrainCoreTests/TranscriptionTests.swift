import Testing
import Foundation
@testable import CallBrainCore

/// Deterministic stubs so the pipeline + alignment are tested without any ML model.
private struct StubTranscriber: Transcriber {
    let modelID = "stub-whisper"
    let segments: [TranscribedSegment]
    func transcribe(_ samples: [Float], progress: @Sendable @escaping (Double) -> Void) async throws -> [TranscribedSegment] {
        progress(0.5); progress(1.0); return segments
    }
}
private struct StubDiarizer: Diarizer {
    let speakers: [SpeakerSegment]
    func diarize(_ samples: [Float]) async throws -> [SpeakerSegment] { speakers }
}

/// Thread-safe collector for the @Sendable progress callback (Swift 6 strict concurrency).
private final class StageBox: @unchecked Sendable {
    private let lock = NSLock(); private var stages: [TranscriptionPipeline.Stage] = []
    func add(_ s: TranscriptionPipeline.Stage) { lock.lock(); if stages.last != s { stages.append(s) }; lock.unlock() }
    func snapshot() -> [TranscriptionPipeline.Stage] { lock.lock(); defer { lock.unlock() }; return stages }
}

@Suite("Transcription pipeline + speaker alignment")
struct TranscriptionTests {

    @Test("midpoint alignment assigns the right speaker and merges consecutive same-speaker segments")
    func alignment() {
        let segments = [
            TranscribedSegment(text: "Hello everyone.", tStart: 0, tEnd: 2),
            TranscribedSegment(text: "Let's start.", tStart: 2, tEnd: 4),     // still speaker 1
            TranscribedSegment(text: "Sounds good.", tStart: 4, tEnd: 6),     // speaker 2
        ]
        let speakers = [
            SpeakerSegment(speaker: "Speaker 1", tStart: 0, tEnd: 4),
            SpeakerSegment(speaker: "Speaker 2", tStart: 4, tEnd: 6),
        ]
        let utts = SpeakerAligner.align(segments, speakers: speakers)
        #expect(utts.count == 2)                                   // first two merged
        #expect(utts[0].speakerRaw == "Speaker 1")
        #expect(utts[0].text == "Hello everyone. Let's start.")
        #expect(utts[0].isInferredSpeaker == false)
        #expect(utts[1].speakerRaw == "Speaker 2")
        #expect(utts[1].text == "Sounds good.")
    }

    @Test("no diarization → single inferred speaker")
    func noDiarization() {
        let utts = SpeakerAligner.align([
            TranscribedSegment(text: "One.", tStart: 0, tEnd: 1),
            TranscribedSegment(text: "Two.", tStart: 1, tEnd: 2),
        ], speakers: [])
        #expect(utts.count == 1)
        #expect(utts[0].isInferredSpeaker == true)
        #expect(utts[0].text == "One. Two.")
    }

    @Test("pipeline.run reports stages and produces a gmeet_local transcript")
    func pipelineStub() async throws {
        // Build a tiny silent wav so AudioDecoder yields samples without needing a real video.
        let url = try Self.makeSilentWav(seconds: 1)
        defer { try? FileManager.default.removeItem(at: url) }

        let pipeline = TranscriptionPipeline(
            transcriber: StubTranscriber(segments: [TranscribedSegment(text: "Hi there.", tStart: 0, tEnd: 1)]),
            diarizer: StubDiarizer(speakers: [SpeakerSegment(speaker: "Speaker 1", tStart: 0, tEnd: 1)]))

        let box = StageBox()
        let parsed = try await pipeline.run(url: url, title: "Recorded standup", date: "2026-06-30") { stage, _ in
            box.add(stage)
        }
        let stages = box.snapshot()
        #expect(parsed.source == .gmeetLocal)
        #expect(parsed.title == "Recorded standup")
        #expect(parsed.utterances.first?.text == "Hi there.")
        #expect(stages.contains(.decoding) && stages.contains(.transcribing) && stages.contains(.finishing))
    }

    /// Minimal 16kHz mono PCM WAV writer (so the decode path runs without a bundled media fixture).
    static func makeSilentWav(seconds: Int) throws -> URL {
        let sr = 16_000, n = sr * seconds
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + n * 2)); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(UInt32(sr)); u32(UInt32(sr * 2)); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(n * 2))
        d.append(Data(count: n * 2))   // silence
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cb-silent-\(UUID().uuidString).wav")
        try d.write(to: url)
        return url
    }
}
