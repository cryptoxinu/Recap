import Foundation
import os
import CallBrainCore
import CallBrainAppCore

/// Launch-time crash recovery (W1b). When a recording is killed mid-call, its rolling checkpoint
/// segments survive under `Recordings/.checkpoints/<mix-stem>/`. On the next launch this reconstructs
/// a complete WAV from those segments and imports it through the SAME durable enqueue + pending-link
/// plumbing `RecordingModel.stop` uses — so a call is never lost. Idempotent: the checkpoint dir is
/// deleted ONLY after the enqueue succeeds, so a second launch simply retries an un-finished one.
extension AppEnvironment {

    /// Reconstruct + import every orphaned checkpoint directory. No-ops when there are none (the common
    /// case). Guarded so a currently-in-progress recording's own dir is never recovered.
    func recoverCrashedRecordings() async {
        let recordingsDir = RecordingStorage.directory()
        let root = recordingsDir.appendingPathComponent(".checkpoints", isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else { return }

        let activeID = activeCheckpointRecordingID   // exclude a live recording's dir (usually nil at launch)
        let orphans = await Task.detached { RecordingRecovery.scan(inRoot: root, excludingActive: activeID) }.value
        guard !orphans.isEmpty else { return }

        let log = Logger(subsystem: "com.callbrain", category: "recording")
        var recoveredAny = false
        for orphan in orphans {
            let dir = orphan.dir, manifest = orphan.manifest
            let segments = manifest.segments
                .map { dir.appendingPathComponent($0) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            guard !segments.isEmpty else {
                try? FileManager.default.removeItem(at: dir)   // nothing on disk to recover → clear the stale dir
                continue
            }

            let dest = Self.recoveredDestination(in: recordingsDir, manifest: manifest)
            // Read + frame-align + write off the main actor (AVFoundation file I/O).
            let merged = await Task.detached { () -> Bool in
                do { try RecordingCheckpointMerger.merge(segments: segments, into: dest); return true }
                catch { return false }
            }.value
            guard merged else {
                log.error("crash-recovery merge failed for \(dir.lastPathComponent, privacy: .public) — will retry next launch")
                continue   // leave the dir for a later launch to retry
            }

            let queued = await importCoordinator.enqueueFilesReturningQueued([dest])
            guard let queuedURL = queued.first else {
                // Enqueue didn't persist → keep the checkpoint dir for a retry, but drop the merged WAV so
                // repeated launches don't accumulate duplicate "Recovered …" files on disk.
                try? FileManager.default.removeItem(at: dest)
                continue
            }

            // Durable start-time hand-off — REUSE the exact row `RecordingModel.stop` writes, keyed by the
            // import payload path, so the recovered meeting lands at the real call time (not launch time).
            let store = self.store
            let began = Date(timeIntervalSince1970: manifest.startedAt)
            _ = await Task.detached {
                (try? store.savePendingRecordingLink(filePath: queuedURL.path, eventID: nil,
                                                     notes: nil, startedAt: began)) != nil
            }.value

            // Delete the checkpoint dir ONLY now that the import is durably queued (idempotent).
            try? FileManager.default.removeItem(at: dir)
            recoveredAny = true
            log.notice("recovered crashed recording \(dir.lastPathComponent, privacy: .public) → \(queuedURL.lastPathComponent, privacy: .public)")
        }
        if recoveredAny { await reconcileRecordingLinks() }
    }

    /// Collision-safe destination for a recovered WAV in the Recordings folder. Prefers the founder's
    /// title (captured before the crash) so the call is findable; falls back to a timestamped default.
    private static func recoveredDestination(in dir: URL, manifest: CheckpointManifest) -> URL {
        let stamp = recoveredStamp(from: manifest.startedAt)
        let title = manifest.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = title.isEmpty ? "Recovered recording — \(stamp)"
                                 : "\(sanitize(title)) (recovered) — \(stamp)"
        var dest = dir.appendingPathComponent("\(base).wav")
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = dir.appendingPathComponent("\(base) (\(n)).wav"); n += 1
        }
        return dest
    }

    private static func recoveredStamp(from epoch: Double) -> String {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HHmm"; df.locale = Locale(identifier: "en_US_POSIX")
        return df.string(from: Date(timeIntervalSince1970: epoch))
    }

    /// Same filename sanitization `RecordingModel` uses (kept local so this file has no MainActor hop).
    private static func sanitize(_ s: String) -> String {
        s.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>")).joined(separator: "-")
    }
}
