import Foundation

/// Single source of truth for WHERE recorded meeting audio lives, plus size + wipe helpers for the
/// Settings surface. Every recording is written here (see `RecordingWriter`), so it's one folder the
/// founder can find, back up, or clear if it grows large. Transcripts + meetings live in the app
/// database and are NOT affected by clearing this folder.
enum RecordingStorage {
    /// The durable recordings folder (Application Support/CallBrain/Recordings), created on demand.
    /// Survives OS temp purges + a failed/slow transcription. Temp only as a last-resort fallback.
    static func directory() -> URL {
        let fm = FileManager.default
        if let support = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                     appropriateFor: nil, create: true) {
            let dir = support.appendingPathComponent("CallBrain/Recordings", isDirectory: true)
            if (try? fm.createDirectory(at: dir, withIntermediateDirectories: true)) != nil { return dir }
        }
        return fm.temporaryDirectory
    }

    /// The recording audio files on disk — REGULAR `.wav` files only (never directories, `.wav` bundles,
    /// or symlinks), so listing + wiping can't be tricked into touching a directory tree (audit MED).
    static func files() -> [URL] {
        let fm = FileManager.default
        let dir = directory().resolvingSymlinksInPath()
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
        let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys,
                                                 options: [.skipsHiddenFiles])) ?? []
        return items.filter { url in
            guard url.pathExtension.lowercased() == "wav" else { return false }
            let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            return (v?.isRegularFile ?? false) && !(v?.isSymbolicLink ?? false)
        }
    }

    static func count() -> Int { files().count }

    /// Total size of the recordings folder, in bytes.
    static func totalBytes() -> Int64 {
        files().reduce(0) { acc, url in
            acc + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
    }

    /// A human-readable size for the whole folder.
    static func formattedSize() -> String {
        ByteCountFormatter.string(fromByteCount: totalBytes(), countStyle: .file)
    }

    /// Delete recorded audio to free space — EXCEPT files whose path is in `protecting` (audio still
    /// backing a pending/failed import, so Retry keeps working — audit HIGH). CONFINED to the real
    /// recordings folder: each file's resolved path must sit inside the resolved root, so a symlinked
    /// path can never make this delete outside the folder (audit HIGH). Transcripts + meetings are
    /// untouched (they're in the database). Returns the number of files deleted.
    @discardableResult
    static func clearAll(protecting: Set<String> = []) -> Int {
        let fm = FileManager.default
        let root = directory().resolvingSymlinksInPath().standardizedFileURL.path
        // Normalize the protected paths the SAME way each directory entry is resolved (audit F10: an
        // unresolved `protecting` path compared against a resolved dir entry could delete a pending/failed
        // import's WAV when the recordings root contains a symlink — `protectedStems` below already resolves).
        let protectingResolved = Set(protecting.map {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path })
        var deleted = 0
        for url in files() {
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            guard resolved.path.hasPrefix(root.hasSuffix("/") ? root : root + "/") else { continue }   // fail closed
            guard !protectingResolved.contains(resolved.path) else { continue }
            if (try? fm.removeItem(at: resolved)) != nil { deleted += 1 }
        }
        // Sweep ALL Meet-caption sidecars in the folder (`<stem>.cbcaptions` / `.cbcaptions.failed`) —
        // including ones stranded by an older clear or a manually-deleted WAV — except those whose WAV is
        // protected by a pending/failed import (audit LOW). Confined to the resolved root, fail-closed.
        let protectedStems = Set(protecting.map { URL(fileURLWithPath: $0).deletingPathExtension()
            .resolvingSymlinksInPath().standardizedFileURL.path })
        let all = (try? fm.contentsOfDirectory(at: directory().resolvingSymlinksInPath(),
                                               includingPropertiesForKeys: [.isRegularFileKey],
                                               options: [.skipsHiddenFiles])) ?? []
        for url in all {
            let last = url.lastPathComponent
            guard last.hasSuffix(".cbcaptions") || last.hasSuffix(".cbcaptions.failed") else { continue }
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            guard resolved.path.hasPrefix(root.hasSuffix("/") ? root : root + "/") else { continue }
            // The sidecar's WAV stem: strip .cbcaptions[.failed] then treat as the <name — stamp> stem.
            let stem = (last.hasSuffix(".failed") ? url.deletingPathExtension() : url).deletingPathExtension()
                .resolvingSymlinksInPath().standardizedFileURL.path
            guard !protectedStems.contains(stem) else { continue }
            try? fm.removeItem(at: resolved)
        }
        // Also sweep the HIDDEN remote-only siblings (`.<stem>.system.wav`, T3). They're dot-prefixed, so
        // this pass enumerates WITHOUT skipsHiddenFiles; still confined to the resolved root + protected stems.
        let hidden = (try? fm.contentsOfDirectory(at: directory().resolvingSymlinksInPath(),
                                                  includingPropertiesForKeys: [.isRegularFileKey],
                                                  options: [])) ?? []
        for url in hidden {
            let last = url.lastPathComponent
            guard last.hasPrefix("."), last.hasSuffix(".system.wav") else { continue }
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            guard resolved.path.hasPrefix(root.hasSuffix("/") ? root : root + "/") else { continue }
            let base = String(last.dropFirst().dropLast(".system.wav".count))   // strip "." and ".system.wav"
            let stem = directory().resolvingSymlinksInPath().appendingPathComponent(base).standardizedFileURL.path
            guard !protectedStems.contains(stem) else { continue }
            try? fm.removeItem(at: resolved)
        }
        return deleted
    }
}
