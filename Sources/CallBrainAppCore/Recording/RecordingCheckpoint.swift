import Foundation
@preconcurrency import AVFoundation

/// Crash-proof recording (W1b). During a live recording the already-mixed Int16 frames are TEE'd
/// (via `AudioMixWriter.onFlushedFrames`) into rolling ~30-second WAV checkpoint segments plus a
/// small `manifest.json`, so that if the app is killed mid-call a launch-time recovery can
/// reconstruct a complete WAV and import it — a call is never lost. On a CLEAN stop the checkpoints
/// are redundant (the main WAV is authoritative) and the whole directory is deleted.
///
/// This file is PURE (no WhisperKit / CoreML): the writer + merger + scanner are unit-testable via
/// `swift test`. The actual recovery merge+enqueue+delete lives in the APP layer (it needs the
/// import coordinator) — only the pure scan + merge are exposed here.

/// The durable description of a crashed recording's checkpoint directory. Written atomically
/// (temp + rename) each time a new segment rolls, so a killed process leaves a manifest that names
/// every segment already on disk.
public struct CheckpointManifest: Codable, Sendable, Equatable {
    public let recordingID: String
    public let title: String
    /// Wall-clock instant the recording began (epoch seconds) — threaded to the recovered meeting's
    /// `start_time` so a recovered call lands at the real time, not midnight-of-day.
    public let startedAt: Double
    /// When this manifest/checkpoint dir was created (epoch seconds) — injected, never `Date.now`, so
    /// the writer stays deterministic-testable.
    public let createdAt: Double
    public let sampleRate: Int
    public let segments: [String]

    public init(recordingID: String, title: String, startedAt: Double, createdAt: Double,
                sampleRate: Int, segments: [String]) {
        self.recordingID = recordingID
        self.title = title
        self.startedAt = startedAt
        self.createdAt = createdAt
        self.sampleRate = sampleRate
        self.segments = segments
    }
}

/// Per-recording checkpoint writer. Receives the already-mixed Int16 frames via `append(_:)` and
/// writes them into rolling WAV segments (`ckpt-000.wav`, `ckpt-001.wav`, …) that roll at
/// `segmentFrames`. All file I/O runs on its OWN serial queue, so `append` NEVER blocks the caller's
/// mix queue (the tee is one non-blocking `q.async`).
public final class RecordingCheckpointWriter: @unchecked Sendable {
    private let q = DispatchQueue(label: "callbrain.rec.checkpoint", qos: .utility)
    private let dir: URL
    private let recordingID: String
    private let title: String
    private let startedAt: Date
    private let createdAt: Date
    private let sampleRate: Int
    private let segmentFrames: Int
    private let target: AVAudioFormat?
    private let settings: [String: Any]

    // queue-only mutable state
    private var currentFile: AVAudioFile?
    private var currentFrameCount = 0
    private var segmentIndex = 0
    private var segments: [String] = []
    private var failed = false

    /// - Parameters:
    ///   - checkpointsRoot: the `.checkpoints` folder inside the durable Recordings directory.
    ///   - recordingID: the mix stem (uuid) — also the sub-directory name.
    ///   - segmentFrames: frames per segment (~30 s @ 16 kHz by default).
    ///   - now: injected creation instant (keep deterministic — never `Date()` inside).
    public init(checkpointsRoot: URL, recordingID: String, title: String, startedAt: Date,
                sampleRate: Int, segmentFrames: Int = 480_000, now: Date) {
        self.recordingID = recordingID
        self.title = title
        self.startedAt = startedAt
        self.createdAt = now
        self.sampleRate = max(1, sampleRate)
        self.segmentFrames = max(1, segmentFrames)
        self.dir = checkpointsRoot.appendingPathComponent(recordingID, isDirectory: true)
        self.settings = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Double(max(1, sampleRate)),
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        self.target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(max(1, sampleRate)),
                                    channels: 1, interleaved: true)
        // Best-effort: a directory-creation failure just disables checkpointing for this recording;
        // it must NEVER break the recording itself (this is additive safety).
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// Tee already-mixed Int16 frames into the rolling segments. NON-BLOCKING: the caller's mix queue
    /// only hands off the (copy-on-write) array; all I/O happens on this writer's own serial queue.
    public func append(_ frames: [Int16]) {
        guard !frames.isEmpty else { return }
        q.async { [weak self] in self?.write(frames) }
    }

    /// Block until every queued `append` has been persisted, WITHOUT deleting anything. For a graceful
    /// barrier (and the crash-recovery test); production shutdown uses `finishClean()`.
    public func waitForPendingWrites() {
        q.sync { }
    }

    /// Clean stop — the main WAV is authoritative, so the checkpoints are redundant: drain any queued
    /// appends (so nothing writes into a just-deleted dir) then remove the whole directory.
    public func finishClean() {
        q.sync {
            currentFile = nil
            try? FileManager.default.removeItem(at: dir)
        }
    }

    // MARK: - queue-only work

    private func write(_ frames: [Int16]) {
        guard !failed, target != nil else { return }
        var offset = 0
        while offset < frames.count {
            if currentFile == nil {
                guard openNextSegment() else { failed = true; return }
            }
            let remaining = segmentFrames - currentFrameCount
            let take = min(remaining, frames.count - offset)
            if take > 0 {
                let slice = Array(frames[offset..<offset + take])
                guard writeFrames(slice) else { failed = true; return }
                currentFrameCount += take
                offset += take
            }
            if currentFrameCount >= segmentFrames {
                currentFile = nil          // roll: the next iteration opens a fresh segment
                currentFrameCount = 0
            }
        }
    }

    private func openNextSegment() -> Bool {
        let name = String(format: "ckpt-%03d.wav", segmentIndex)
        let url = dir.appendingPathComponent(name)
        guard let f = try? AVAudioFile(forWriting: url, settings: settings,
                                       commonFormat: .pcmFormatInt16, interleaved: true) else { return false }
        currentFile = f
        currentFrameCount = 0
        segmentIndex += 1
        segments.append(name)
        writeManifest()                    // atomically record the new segment BEFORE we fill it
        return true
    }

    private func writeFrames(_ frames: [Int16]) -> Bool {
        guard let file = currentFile, let target, !frames.isEmpty else { return true }
        guard let buf = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(frames.count)),
              let dst = buf.int16ChannelData else { return false }
        buf.frameLength = AVAudioFrameCount(frames.count)
        for i in 0..<frames.count { dst[0][i] = frames[i] }
        do { try file.write(from: buf); return true } catch { return false }
    }

    /// Write the manifest atomically (write to a unique temp sibling on the same volume, then rename
    /// over the final path) so a crash never leaves a half-written manifest.
    private func writeManifest() {
        let manifest = CheckpointManifest(
            recordingID: recordingID, title: title,
            startedAt: startedAt.timeIntervalSince1970, createdAt: createdAt.timeIntervalSince1970,
            sampleRate: sampleRate, segments: segments)
        guard let data = try? JSONEncoder().encode(manifest) else { return }
        let fm = FileManager.default
        let final = dir.appendingPathComponent("manifest.json")
        let tmp = dir.appendingPathComponent("manifest.\(UUID().uuidString).tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            if fm.fileExists(atPath: final.path) {
                _ = try fm.replaceItemAt(final, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: final)
            }
        } catch {
            try? fm.removeItem(at: tmp)     // don't leak the temp on failure
        }
    }
}

public enum RecordingCheckpointError: Error, Sendable {
    case cannotCreateOutput
}

/// Pure helpers to inspect + reconstruct crashed recordings' checkpoint directories.
public enum RecordingCheckpointMerger {

    /// The immediate sub-directories of `root` (one per recording), sorted by name for a stable order.
    public static func recordingDirs(inRoot root: URL) -> [URL] {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                 options: [])) ?? []
        return items
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    public static func readManifest(_ dir: URL) -> CheckpointManifest? {
        let url = dir.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CheckpointManifest.self, from: data)
    }

    /// Frame-aligned concatenation of the numbered 16 kHz-mono-Int16 WAV `segments` into one WAV at
    /// `dest`. All segments share the same format, so this is a straight append. An UNREADABLE segment
    /// (e.g. a truly-crashed trailing segment with a torn header) is SKIPPED — recover what survived —
    /// rather than aborting the whole recovery. Throws only if the destination can't be created.
    public static func merge(segments: [URL], into dest: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        guard let out = try? AVAudioFile(forWriting: dest, settings: settings,
                                         commonFormat: .pcmFormatInt16, interleaved: true) else {
            throw RecordingCheckpointError.cannotCreateOutput
        }
        for seg in segments {
            guard let inFile = try? AVAudioFile(forReading: seg, commonFormat: .pcmFormatInt16,
                                                interleaved: true) else { continue }
            let frameCount = AVAudioFrameCount(inFile.length)
            guard frameCount > 0,
                  let buf = AVAudioPCMBuffer(pcmFormat: inFile.processingFormat, frameCapacity: frameCount)
            else { continue }
            do {
                try inFile.read(into: buf)
                try out.write(from: buf)
            } catch { continue }           // skip a torn segment; keep everything before it
        }
    }
}

/// Pure launch scan for orphaned checkpoint directories. The APP layer drives the merge → enqueue →
/// delete (it needs the import coordinator); this only enumerates the recoverable dirs so the scan is
/// unit-testable.
public enum RecordingRecovery {
    /// Every checkpoint directory under `root` that carries a readable manifest, EXCLUDING the one
    /// whose recording is currently in progress (`excludingActive`, matched on either the manifest's
    /// `recordingID` or the directory name) so a live recording is never "recovered" out from under
    /// itself.
    public static func scan(inRoot root: URL, excludingActive activeID: String?) -> [(dir: URL, manifest: CheckpointManifest)] {
        RecordingCheckpointMerger.recordingDirs(inRoot: root).compactMap { dir in
            guard let manifest = RecordingCheckpointMerger.readManifest(dir) else { return nil }
            if let activeID, !activeID.isEmpty,
               manifest.recordingID == activeID || dir.lastPathComponent == activeID { return nil }
            return (dir, manifest)
        }
    }
}
