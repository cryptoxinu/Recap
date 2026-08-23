import Testing
import Foundation
import AVFoundation
import CallBrainAppCore
import CallBrainCore

/// Crash-proof recording (W1b). Drives the synthetic two-band tone timeline through the REAL
/// `AudioMixWriter` with a `RecordingCheckpointWriter` wired via `onFlushedFrames`, then SIMULATES A
/// CRASH — drops the writers WITHOUT `close()`/`finishClean()` — and proves the orphaned checkpoint
/// segments reconstruct a complete WAV that still carries both speakers. A second test proves a CLEAN
/// stop (`close()` + `finishClean()`) leaves no checkpoint directory behind.
@Suite("RecordingCheckpoint — crash recovery merge + clean-stop cleanup")
struct CheckpointMergeTests {

    private static let sr = SyntheticAudio.sampleRate

    private static func target() -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sr, channels: 1, interleaved: true)!
    }

    private static func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cb-checkpoint-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("crash mid-recording → merged segments reconstruct a complete WAV with both bands")
    func crashRecoveryMergesSegments() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let checkpointsRoot = root.appendingPathComponent(".checkpoints", isDirectory: true)
        let mixURL = root.appendingPathComponent("mix.wav")
        let recordingID = "rec-\(UUID().uuidString)"

        let writer = AudioMixWriter(mixURL: mixURL, systemSidecarURL: nil, target: Self.target(),
                                    micSourceRate: Self.sr, gateEnabled: false, onLevel: { _ in })
        try #require(writer != nil)
        let w = writer!

        // Small 1 s segments so a 4.5 s clip rolls SEVERAL checkpoint segments (ckpt-000…ckpt-004).
        let checkpoint = RecordingCheckpointWriter(
            checkpointsRoot: checkpointsRoot, recordingID: recordingID, title: "Standup",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000), sampleRate: 16_000,
            segmentFrames: 16_000, now: Date(timeIntervalSince1970: 1_700_000_000))
        w.onFlushedFrames = { [checkpoint] frames in checkpoint.append(frames) }

        drive(SineFrameSource(), into: w)
        // Drain the mix queue via one final periodic-style flush (this is NOT close(): the main WAV is
        // never finalized and the resampler tail is never drained) — models a kill right after the last
        // checkpoint was persisted. Then barrier the checkpoint queue so all segments are on disk.
        w.flushPending()
        checkpoint.waitForPendingWrites()
        // Simulate the crash: neither w.close() nor checkpoint.finishClean() runs — segments survive.

        let dir = checkpointsRoot.appendingPathComponent(recordingID, isDirectory: true)
        let manifest = try #require(RecordingCheckpointMerger.readManifest(dir))
        #expect(manifest.recordingID == recordingID)
        #expect(manifest.title == "Standup")
        #expect(manifest.segments.count >= 2)   // several segments rolled
        let segments = manifest.segments.map { dir.appendingPathComponent($0) }

        let dest = root.appendingPathComponent("recovered.wav")
        try RecordingCheckpointMerger.merge(segments: segments, into: dest)

        let merged = try await AudioDecoder.decode16kMono(url: dest)
        #expect(merged.count > 0)

        // Duration ≈ fed length (4.5 s), tolerating at most the un-flushed tail window.
        let dur = AudioDecoder.duration(samples: merged.count)
        #expect(dur >= 4.0 && dur <= 4.7)

        // BOTH speakers survive the crash at the right windows.
        #expect(Goertzel.bandDominates(merged, target: 300, over: 900, sampleRate: Self.sr, in: 0.2..<0.8))
        #expect(Goertzel.bandDominates(merged, target: 300, over: 900, sampleRate: Self.sr, in: 2.2..<2.8))
        #expect(Goertzel.bandDominates(merged, target: 900, over: 300, sampleRate: Self.sr, in: 1.2..<1.8))
        #expect(Goertzel.bandDominates(merged, target: 900, over: 300, sampleRate: Self.sr, in: 3.2..<3.8))
    }

    @Test("clean stop → finishClean() removes the checkpoint directory")
    func cleanStopRemovesCheckpointDir() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let checkpointsRoot = root.appendingPathComponent(".checkpoints", isDirectory: true)
        let mixURL = root.appendingPathComponent("mix.wav")
        let recordingID = "rec-\(UUID().uuidString)"

        let writer = AudioMixWriter(mixURL: mixURL, systemSidecarURL: nil, target: Self.target(),
                                    micSourceRate: Self.sr, gateEnabled: false, onLevel: { _ in })
        try #require(writer != nil)
        let w = writer!
        let checkpoint = RecordingCheckpointWriter(
            checkpointsRoot: checkpointsRoot, recordingID: recordingID, title: "",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000), sampleRate: 16_000,
            segmentFrames: 16_000, now: Date(timeIntervalSince1970: 1_700_000_000))
        w.onFlushedFrames = { [checkpoint] frames in checkpoint.append(frames) }

        drive(SineFrameSource(), into: w)
        _ = w.close()                       // final flush fires the last tee'd append
        checkpoint.waitForPendingWrites()   // ensure segments were actually written before we assert

        let dir = checkpointsRoot.appendingPathComponent(recordingID, isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: dir.path))   // checkpoints existed mid-recording

        checkpoint.finishClean()
        #expect(FileManager.default.fileExists(atPath: dir.path) == false)   // …and are gone after a clean stop
    }
}
