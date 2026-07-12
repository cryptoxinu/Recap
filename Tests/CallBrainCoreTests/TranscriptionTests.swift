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
        // Diarized "Speaker N" labels + model timestamps are inferred/derived per CTM (gate fix).
        #expect(utts[0].isInferredSpeaker == true)
        #expect(utts[0].tsConfidence == .derived)
        #expect(utts[1].speakerRaw == "Speaker 2")
        #expect(utts[1].text == "Sounds good.")
    }

    @Test("dual-channel: remote-span segments get the remote speaker; everything else is the founder (T3)")
    func founderVsRemote() {
        let segments = [
            TranscribedSegment(text: "Welcome, let's dive in.", tStart: 0, tEnd: 3),   // founder (no remote span)
            TranscribedSegment(text: "Thanks for having me.", tStart: 3, tEnd: 6),      // remote — Speaker 1
            TranscribedSegment(text: "I agree with that.", tStart: 6, tEnd: 9),         // remote — Speaker 2
            TranscribedSegment(text: "Great, so next steps.", tStart: 9, tEnd: 12),     // back to founder
        ]
        let remote = [
            SpeakerSegment(speaker: "Speaker 1", tStart: 3, tEnd: 6),
            SpeakerSegment(speaker: "Speaker 2", tStart: 6, tEnd: 9),
        ]
        let utts = SpeakerAligner.alignFounderVsRemote(segments, remoteSpeakers: remote, founderName: "Alex")
        #expect(utts.map(\.speakerRaw) == ["Alex", "Speaker 1", "Speaker 2", "Alex"])
        #expect(utts[0].text == "Welcome, let's dive in.")
        #expect(utts[3].text == "Great, so next steps.")
        #expect(utts.allSatisfy { $0.speakerConfidence == 0.85 })
        #expect(utts.allSatisfy { $0.isInferredSpeaker && $0.tsConfidence == .derived })
    }

    @Test("dual-channel: consecutive founder segments merge; a founder segment NEAR a remote span stays founder")
    func founderVsRemoteMergeAndBoundary() {
        let segments = [
            TranscribedSegment(text: "One.", tStart: 0, tEnd: 2),     // founder
            TranscribedSegment(text: "Two.", tStart: 2, tEnd: 4),     // founder (merges)
            TranscribedSegment(text: "Near.", tStart: 9.5, tEnd: 10), // 0.5s BEFORE a remote span → still founder
        ]
        let remote = [SpeakerSegment(speaker: "Speaker 1", tStart: 10, tEnd: 14)]
        let utts = SpeakerAligner.alignFounderVsRemote(segments, remoteSpeakers: remote, founderName: "Alex")
        #expect(utts.count == 1)                                     // all three are the founder, merged
        #expect(utts[0].speakerRaw == "Alex")
        #expect(utts[0].text == "One. Two. Near.")
    }

    @Test("dual-channel: a brief remote backchannel over a founder segment's midpoint does NOT steal it (overlap, audit MED)")
    func founderVsRemoteBackchannel() {
        // Founder speaks one long segment [10,16] (mid 13). A remote 'mm-hmm' turn [12.8,13.3] straddles the
        // midpoint — with midpoint containment this WOULD flip the whole 6s turn to the remote. Overlap = 0.5s
        // of 6s (< 50%) → stays the founder.
        let segments = [TranscribedSegment(text: "A long founder point that runs on.", tStart: 10, tEnd: 16)]
        let remote = [SpeakerSegment(speaker: "Speaker 2", tStart: 12.8, tEnd: 13.3)]
        let utts = SpeakerAligner.alignFounderVsRemote(segments, remoteSpeakers: remote, founderName: "Alex")
        #expect(utts.first?.speakerRaw == "Alex")
    }

    @Test("dual-channel: a remote utterance split by a breath-gap still resolves to that remote (summed overlap, audit MED)")
    func founderVsRemoteBreathGap() {
        // A purely-remote utterance transcribed as one segment [20,24] (mid 22.0). FluidAudio split it into
        // [20,21.8] + [22.3,24] by a breath — the midpoint 22.0 lands in the 21.8–22.3 gap. Summed Speaker-2
        // overlap = 1.8 + 1.7 = 3.5 of 4s (>= 50%) → correctly the remote speaker, not the founder.
        let segments = [TranscribedSegment(text: "Remote person's full sentence.", tStart: 20, tEnd: 24)]
        let remote = [
            SpeakerSegment(speaker: "Speaker 2", tStart: 20, tEnd: 21.8),
            SpeakerSegment(speaker: "Speaker 2", tStart: 22.3, tEnd: 24),
        ]
        let utts = SpeakerAligner.alignFounderVsRemote(segments, remoteSpeakers: remote, founderName: "Alex")
        #expect(utts.first?.speakerRaw == "Speaker 2")
    }

    @Test("dual-channel: no remote speakers (mic-only recording) → every segment is the founder")
    func founderVsRemoteMicOnly() {
        let segments = [
            TranscribedSegment(text: "Just me talking.", tStart: 0, tEnd: 3),
            TranscribedSegment(text: "Still me.", tStart: 3, tEnd: 5),
        ]
        let utts = SpeakerAligner.alignFounderVsRemote(segments, remoteSpeakers: [], founderName: "Alex")
        #expect(utts.count == 1)
        #expect(utts[0].speakerRaw == "Alex")
        #expect(utts[0].text == "Just me talking. Still me.")
    }

    @Test("a segment in a long gap is NOT attributed to a far speaker (max-gap; gate MED)")
    func maxGapFallback() {
        let speakers = [SpeakerSegment(speaker: "Speaker 1", tStart: 0, tEnd: 5)]
        // a segment at 60s — 55s after the only speaker turn → must fall back, not attribute to Speaker 1
        #expect(SpeakerAligner.speakerFor(midpoint: 60, in: speakers) == nil)
        // a segment 1s after the turn → within max-gap → attributed
        #expect(SpeakerAligner.speakerFor(midpoint: 5.5, in: speakers) == "Speaker 1")
    }

    @Test("a gap segment is labeled Unknown with NO confidence, not a confident Speaker 1 (D3)")
    func gapSegmentUnattributed() {
        let segments = [
            TranscribedSegment(text: "On topic.", tStart: 0, tEnd: 4),      // inside Speaker 1's turn
            TranscribedSegment(text: "Hold music.", tStart: 60, tEnd: 62),  // 55s gap → no speaker
        ]
        let speakers = [SpeakerSegment(speaker: "Speaker 1", tStart: 0, tEnd: 5)]
        let utts = SpeakerAligner.align(segments, speakers: speakers)
        #expect(utts.count == 2)
        #expect(utts[0].speakerRaw == "Speaker 1")
        #expect(utts[0].speakerConfidence == 0.8)              // matched → confident
        #expect(utts[1].speakerRaw == SpeakerAligner.unattributed)
        #expect(utts[1].speakerConfidence == nil)              // gap → NO false certainty
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
        let out = try await pipeline.run(url: url, title: "Recorded standup", date: "2026-06-30") { stage, _ in
            box.add(stage)
        }
        let stages = box.snapshot()
        #expect(out.transcript.source == .gmeetLocal)
        #expect(out.transcript.title == "Recorded standup")
        #expect(out.transcript.utterances.first?.text == "Hi there.")
        #expect(out.diarizationRequested == true)
        #expect(out.diarizationSucceeded == true)
        #expect(stages.contains(.decoding) && stages.contains(.transcribing) && stages.contains(.finishing))
    }

    @Test("pipeline dual-channel: a system track routes attribution to founder-vs-remote (T3)")
    func pipelineDual() async throws {
        let mixed = try Self.makeSilentWav(seconds: 1); defer { try? FileManager.default.removeItem(at: mixed) }
        let system = try Self.makeSilentWav(seconds: 1); defer { try? FileManager.default.removeItem(at: system) }
        let pipeline = TranscriptionPipeline(
            transcriber: StubTranscriber(segments: [
                TranscribedSegment(text: "Hello team.", tStart: 0, tEnd: 0.4),   // founder — no remote span
                TranscribedSegment(text: "Hi there.", tStart: 0.5, tEnd: 0.9),   // remote — Speaker 1
            ]),
            diarizer: StubDiarizer(speakers: [SpeakerSegment(speaker: "Speaker 1", tStart: 0.5, tEnd: 0.9)]))
        let out = try await pipeline.run(url: mixed, title: "Standup", date: "2026-07-08",
                                         systemAudioURL: system, founderName: "Alex")
        #expect(out.transcript.utterances.map(\.speakerRaw) == ["Alex", "Speaker 1"])
        #expect(out.transcript.speakers.contains("Alex"))
        #expect(out.diarizationSucceeded == true)
    }

    @Test("pipeline dual-channel: EMPTY remote diarization does NOT blanket-label the call as the founder (audit HIGH)")
    func pipelineDualEmptyRemoteFallsBack() async throws {
        let mixed = try Self.makeSilentWav(seconds: 1); defer { try? FileManager.default.removeItem(at: mixed) }
        let system = try Self.makeSilentWav(seconds: 1); defer { try? FileManager.default.removeItem(at: system) }
        // Remote diarization yields nothing → must fall back to mono alignment, never relabel all as founder.
        let pipeline = TranscriptionPipeline(
            transcriber: StubTranscriber(segments: [TranscribedSegment(text: "Hello.", tStart: 0, tEnd: 1)]),
            diarizer: StubDiarizer(speakers: []))
        let out = try await pipeline.run(url: mixed, title: "S", date: "2026-07-08",
                                         systemAudioURL: system, founderName: "Alex")
        #expect(out.transcript.utterances.first?.speakerRaw != "Alex")             // NOT the all-founder bug
        #expect(out.transcript.utterances.first?.speakerRaw == SpeakerAligner.unattributed)
    }

    @Test("pipeline dual-channel: a MISSING system track cleanly degrades to mono alignment")
    func pipelineDualMissingSystem() async throws {
        let mixed = try Self.makeSilentWav(seconds: 1); defer { try? FileManager.default.removeItem(at: mixed) }
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("cb-nope-\(UUID().uuidString).wav")
        let pipeline = TranscriptionPipeline(
            transcriber: StubTranscriber(segments: [TranscribedSegment(text: "Hi there.", tStart: 0, tEnd: 1)]),
            diarizer: StubDiarizer(speakers: [SpeakerSegment(speaker: "Speaker 1", tStart: 0, tEnd: 1)]))
        let out = try await pipeline.run(url: mixed, title: "Standup", date: "2026-07-08",
                                         systemAudioURL: missing, founderName: "Alex")
        // No system track → original mono midpoint alignment → the diarized label, not a founder split.
        #expect(out.transcript.utterances.first?.speakerRaw == "Speaker 1")
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
