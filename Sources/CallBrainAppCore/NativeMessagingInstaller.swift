import Foundation

/// Installs the Chrome Native Messaging host manifest + maintains the on-disk bridge the host reads
/// (Phase 4). Mirrors `CorpusSyncInstaller`'s pattern: pure builders for tests + thin FS writers.
///
/// - The **host manifest** tells each Chromium browser it may launch `cbpairhost` for our pinned
///   extension id (`allowed_origins`). Written to every installed Chromium family's
///   `NativeMessagingHosts/` directory.
/// - The **bridge file** (`~/Library/Application Support/CallBrain/pair-bridge.json`, 0600 in a 0700
///   dir) carries the current loopback token + port. The app rewrites it whenever the server (re)binds;
///   the host reads it and hands it to the extension over Chrome's authenticated stdio channel.
public enum NativeMessagingError: LocalizedError, Equatable {
    /// The bridge file couldn't be locked to 0600 (its final mode is reported).
    case bridgePermissions(Int)
    public var errorDescription: String? {
        switch self {
        case .bridgePermissions(let mode):
            return "Pairing bridge file could not be secured (mode \(String(mode, radix: 8)) ≠ 600)."
        }
    }
}

public enum NativeMessagingInstaller {

    public static let hostName = "com.callbrain.pair"
    /// The pinned extension origin — MUST match `LocalServerCore.expectedExtensionOrigin`'s id. Chrome
    /// requires the trailing slash form in `allowed_origins`.
    public static let allowedOrigin = "chrome-extension://lcmphiaobpklepliifghlmpdiblkfgpm/"

    // MARK: - Pure builders (tested)

    /// The manifest JSON Chrome reads. `hostPath` must be the ABSOLUTE path to the `cbpairhost` binary
    /// inside the running app bundle (Chrome rejects relative paths).
    public static func hostManifest(hostPath: String) -> Data {
        let obj: [String: Any] = [
            "name": hostName,
            "description": "Recap pairing bridge — hands the loopback token to the Recap browser extension.",
            "path": hostPath,
            "type": "stdio",
            "allowed_origins": [allowedOrigin],
        ]
        // Sorted keys so the on-disk file is stable across writes (no churn / easier to diff).
        return (try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]))
            ?? Data("{}".utf8)
    }

    /// The Application-Support subdirectories of every Chromium family we support. We install the host
    /// manifest into `<family>/NativeMessagingHosts/` for each family whose base dir actually exists, so
    /// we never create stray directories for browsers the user doesn't have.
    static let browserBaseSubpaths = [
        "Google/Chrome",
        "Google/Chrome Beta",
        "Google/Chrome Dev",
        "Google/Chrome Canary",
        "Chromium",
        "BraveSoftware/Brave-Browser",
        "Microsoft Edge",
        "Arc",
        "Vivaldi",
    ]

    /// The `NativeMessagingHosts` directories to install into, given the user's Application Support root
    /// — only for browser families that are actually installed (their base dir exists).
    public static func targetDirectories(applicationSupport: URL, fileManager: FileManager = .default) -> [URL] {
        browserBaseSubpaths.compactMap { sub in
            let base = applicationSupport.appendingPathComponent(sub, isDirectory: true)
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: base.path, isDirectory: &isDir), isDir.boolValue else { return nil }
            return base.appendingPathComponent("NativeMessagingHosts", isDirectory: true)
        }
    }

    /// The 0600 bridge file the host reads for the live token + port.
    public static func bridgeFileURL(applicationSupport: URL) -> URL {
        applicationSupport
            .appendingPathComponent("CallBrain", isDirectory: true)
            .appendingPathComponent("pair-bridge.json", isDirectory: false)
    }

    public static func bridgeContent(token: String, port: UInt16) -> Data {
        (try? JSONEncoder().encode(PairBridgePayload(token: token, port: Int(port))))
            ?? Data("{}".utf8)
    }

    // MARK: - Filesystem installation

    /// Write the host manifest into every installed Chromium family's `NativeMessagingHosts/` dir.
    /// Best-effort + idempotent: a browser we can't write to (perms) is skipped, not fatal. Returns the
    /// directories actually written, for logging.
    @discardableResult
    public static func installHostManifest(hostPath: String,
                                           applicationSupport: URL,
                                           fileManager: FileManager = .default) -> [URL] {
        let manifest = hostManifest(hostPath: hostPath)
        var written: [URL] = []
        for dir in targetDirectories(applicationSupport: applicationSupport, fileManager: fileManager) {
            do {
                try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
                let file = dir.appendingPathComponent("\(hostName).json", isDirectory: false)
                try manifest.write(to: file, options: [.atomic])
                written.append(file)
            } catch { continue }
        }
        return written
    }

    /// Write (or refresh) the 0600 bridge file with the live token + port, in a 0700 dir. Called on every
    /// server (re)bind. Returns the bridge URL on success. THROWS if the file can't be locked down to 0600
    /// (or the dir to 0700) — a bearer token left group/world-readable is a security failure, never a
    /// silent "success" (audit HIGH). On such a failure the just-written file is removed so no readable
    /// token lingers.
    @discardableResult
    public static func writeBridge(token: String, port: UInt16,
                                   applicationSupport: URL,
                                   fileManager: FileManager = .default) throws -> URL {
        var dir = applicationSupport.appendingPathComponent("CallBrain", isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        // Tighten the dir even if it pre-existed with looser perms — propagate a failure, don't swallow it.
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        // Keep the live bearer token out of Time Machine / iCloud backups (a Keychain ThisDeviceOnly item
        // is auto-excluded; a plain file is not) — best-effort, mirrors the token's device-only intent.
        var dirValues = URLResourceValues(); dirValues.isExcludedFromBackup = true
        try? dir.setResourceValues(dirValues)
        var file = bridgeFileURL(applicationSupport: applicationSupport)
        try bridgeContent(token: token, port: port).write(to: file, options: [.atomic])
        do {
            // `.atomic` writes via a temp file + rename, which can reset perms — set 0600 explicitly, then
            // VERIFY it actually stuck (some filesystems ignore chmod) before trusting the token on disk.
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            let mode = (try fileManager.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue
            guard mode == 0o600 else {
                throw NativeMessagingError.bridgePermissions(mode ?? -1)
            }
        } catch {
            try? fileManager.removeItem(at: file)   // don't leave a readable token behind
            throw error
        }
        var fileValues = URLResourceValues(); fileValues.isExcludedFromBackup = true
        try? file.setResourceValues(fileValues)
        return file
    }

    /// Remove the bridge file (e.g. on quit) so the live token isn't left on disk longer than needed.
    /// Best-effort — a leftover file is harmless (the host re-reads whatever's current on next launch).
    public static func removeBridge(applicationSupport: URL, fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: bridgeFileURL(applicationSupport: applicationSupport))
    }

    /// Remove any Recap host manifests we previously installed — used when the bundled `cbpairhost`
    /// binary is absent (a dev `swift run`, or a stripped build), so Chrome never advertises a host whose
    /// path points at a missing/stale binary (audit MED). Best-effort per browser.
    public static func removeHostManifest(applicationSupport: URL, fileManager: FileManager = .default) {
        for dir in targetDirectories(applicationSupport: applicationSupport, fileManager: fileManager) {
            try? fileManager.removeItem(at: dir.appendingPathComponent("\(hostName).json", isDirectory: false))
        }
    }

    /// Read the bridge file — used by the `cbpairhost` binary. Returns nil when Recap isn't running
    /// / hasn't paired (no file yet), or the file is unreadable/corrupt.
    public static func readBridge(applicationSupport: URL, fileManager: FileManager = .default) -> PairBridgePayload? {
        let file = bridgeFileURL(applicationSupport: applicationSupport)
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(PairBridgePayload.self, from: data)
    }

    /// The user's Application Support root — the anchor for every path above.
    public static func defaultApplicationSupport(fileManager: FileManager = .default) -> URL {
        if let url = try? fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                          appropriateFor: nil, create: false) {
            return url
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
    }
}
