import SwiftUI
import CoreServices
import CallBrainCore

/// "Set it and forget it" auto-import (founder request 2026-06-30): watch one local folder (e.g. a
/// Google-Drive-synced "Meet Recordings" folder) and import new transcripts/recordings as they appear —
/// no manual step. Uses FSEvents (native, event-driven, no polling). Content-hash dedupe + a per-path
/// "seen" set mean a file is only ever imported once. The Drive *API* (no desktop-sync needed) is a
/// future add that requires the founder's Google OAuth.
@MainActor
@Observable
final class FolderAutoImport {
    private let env: AppEnvironment
    private(set) var folderPath: String?
    private(set) var importedCount = 0
    private var watcher: FolderWatch?

    static let folderKey = "callbrain.autoImportFolder"
    static let seenKey = "callbrain.autoImportSeenPaths"

    init(env: AppEnvironment) {
        self.env = env
        // QA launches (CALLBRAIN_SKIP_RECONCILE=1) don't start the watcher, so a UI test doesn't trip a
        // TCC folder-access prompt on a freshly re-signed dev build.
        guard !FathomConnect.qaSkipReconcile,
              let p = UserDefaults.standard.string(forKey: Self.folderKey),
              FileManager.default.fileExists(atPath: p) else { return }
        start(path: p)
    }

    var isWatching: Bool { folderPath != nil }

    /// Choose (or clear) the watched folder. Picking one does an immediate catch-up scan, then watches.
    func setFolder(_ url: URL?) {
        stop()
        guard let url else {
            folderPath = nil
            UserDefaults.standard.removeObject(forKey: Self.folderKey)
            return
        }
        UserDefaults.standard.set(url.path, forKey: Self.folderKey)
        start(path: url.path)
    }

    private func start(path: String) {
        folderPath = path
        rescan()                                   // catch up on whatever's already there
        watcher = FolderWatch(path: path) { [weak self] in
            Task { @MainActor in self?.rescan() }
        }
    }

    private func stop() { watcher?.stop(); watcher = nil }

    static let seenCap = 5000   // bound the "already auto-imported" list (content-hash dedupe is the backstop)

    /// Identity for the seen-set: path + size + mtime, so a file that CHANGES (a partial download
    /// completing) is treated as fresh rather than permanently skipped by path alone (audit D1).
    static func fileKey(_ url: URL) -> String {
        let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = v?.fileSize ?? 0
        let mtime = Int(v?.contentModificationDate?.timeIntervalSince1970 ?? 0)
        return "\(url.path)|\(size)|\(mtime)"
    }

    /// Enqueue files we haven't auto-imported before (the content-hash dedupe is the backstop).
    private func rescan() {
        guard let folderPath else { return }
        let recognized = IngestEngine.readableExtensions.union(ImportCoordinator.mediaExtensions)
        Task { [weak self] in
            // Walk the folder OFF the main thread so a big drop never freezes the UI.
            let found = await Task.detached {
                FolderScanner.importableFiles(in: URL(fileURLWithPath: folderPath), recognized: recognized)
            }.value
            guard let self else { return }
            var seenArr = UserDefaults.standard.stringArray(forKey: Self.seenKey) ?? []
            let seen = Set(seenArr)
            // Key by path + SIZE + mtime, not path alone: a PARTIAL Google Drive download that
            // queued, failed to parse, and got marked seen would otherwise be skipped forever once
            // the FULL file lands — but the completed file has a different size/mtime, so it now
            // re-detects as fresh (content-hash dedupe is still the backstop against real dupes)
            // (audit D1 HIGH).
            let fresh = found.filter { !seen.contains(Self.fileKey($0)) }
            guard !fresh.isEmpty else { return }
            let queued = await self.env.importCoordinator.enqueueFilesReturningQueued(fresh)
            seenArr.append(contentsOf: queued.map { Self.fileKey($0) })
            if seenArr.count > Self.seenCap { seenArr = Array(seenArr.suffix(Self.seenCap)) }   // keep most recent
            UserDefaults.standard.set(seenArr, forKey: Self.seenKey)
            self.importedCount += queued.count
        }
    }
}

/// Thin FSEvents wrapper: fires `onChange` (coalesced) when anything under `path` changes. `@unchecked
/// Sendable` — the C callback hops to the main actor; only the retained `info` pointer crosses threads.
final class FolderWatch: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let onChange: @Sendable () -> Void

    init(path: String, onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        // RETAIN self across the C boundary (audit MED: use-after-free). The FSEvents callback fires on a
        // background queue; with only an unretained pointer, a callback racing a folder switch (stop() +
        // dealloc on the main actor) would deref freed memory. passRetained + a matching release callback
        // keeps this FolderWatch alive as long as the stream holds it; the release fires on FSEventStreamRelease.
        var ctx = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passRetained(self).toOpaque(),
            retain: nil,
            release: { info in if let info { Unmanaged<FolderWatch>.fromOpaque(info).release() } },
            copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(kCFAllocatorDefault, fsCallback, &ctx,
                                          [path] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                          2.0, flags) else {
            if let info = ctx.info { Unmanaged<FolderWatch>.fromOpaque(info).release() }   // balance passRetained
            return
        }
        stream = s
        FSEventStreamSetDispatchQueue(s, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(s)
    }

    func fire() { onChange() }

    func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s)
        stream = nil
    }
    deinit { stop() }
}

/// FSEvents C callback — retrieves the watcher from `info` and fires its coalesced change handler.
private func fsCallback(_ stream: ConstFSEventStreamRef, _ info: UnsafeMutableRawPointer?,
                        _ numEvents: Int, _ paths: UnsafeMutableRawPointer,
                        _ flags: UnsafePointer<FSEventStreamEventFlags>,
                        _ ids: UnsafePointer<FSEventStreamEventId>) {
    guard let info else { return }
    Unmanaged<FolderWatch>.fromOpaque(info).takeUnretainedValue().fire()
}
