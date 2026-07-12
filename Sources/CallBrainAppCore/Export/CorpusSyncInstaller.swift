import Foundation

/// Installs / removes the LaunchAgent that rsyncs the corpus folder to the founder's server Mac over
/// Tailscale (Part B6). Design:
/// - **One-directional push** into a dedicated Recap-owned dest folder the bot only READS, so
///   `rsync --delete` can never touch the bot's own index/db (which live elsewhere).
/// - **GNU rsync, forced on BOTH ends** (`-a --delete --mkpath`, `--rsync-path` pins the server to its
///   Homebrew rsync): macOS's `/usr/bin/rsync` is openrsync, which reports success but writes NOTHING
///   over ssh between two Macs. NO `--partial` — rsync renames each file into place only on completion,
///   so the bot never reads a half-written file (and no `-z`/`--info`, which openrsync also lacked).
/// - **Marker guard** in the script: never sync from a folder missing `.callbrain-corpus` (so an empty /
///   half-provisioned source can't `--delete`-wipe the server).
/// - **Transport is Tailscale (WireGuard) + ssh** to a `*.ts.net` MagicDNS name — the name only resolves
///   over the tailnet, so the push fails closed if Tailscale is down (never falls back to the open
///   internet). `BatchMode=yes -o ConnectTimeout=10` fails fast (no password prompt / hang) until the
///   founder enables Tailscale SSH on the server; `StrictHostKeyChecking=accept-new` is TOFU, which is
///   safe here because Tailscale already cryptographically authenticates the peer (a first-connect MITM
///   isn't reachable on the tailnet) and a CHANGED host key is still rejected. Retries on the next
///   WatchPaths / interval trigger.
///
/// The pure `scriptBody` / `plistBody` / `shellQuote` are unit-tested; the file-write + `launchctl` I/O is
/// founder-side (validated on the real two-Mac setup).
public enum CorpusSyncInstaller {

    public static let label = "com.callbrain.corpus-sync"
    public static let hostKey = "callbrain.corpus.syncHost"
    public static let destKey = "callbrain.corpus.syncDest"
    // The server Mac's Tailscale MagicDNS name. The REAL host is set per-machine in local prefs
    // (`callbrain.corpus.syncHost`) so no personal machine/tailnet name is baked into the source; this
    // placeholder is only the fallback when that pref is unset. `isSafeHost` requires a `.ts.net` suffix,
    // so the relay stays pinned to Tailscale (WireGuard) and can never route transcripts over the open net.
    // To set it on a machine: `defaults write com.callbrain.app callbrain.corpus.syncHost 'your-mac.your-tailnet.ts.net'`.
    public static let defaultHost = "your-server.ts.net"
    public static let defaultDest = "callbrain-corpus"        // server-side folder the bot reads (relative to $HOME)

    public static func host(_ defaults: UserDefaults = .standard) -> String {
        let value = defaults.string(forKey: hostKey)?.trimmingCharacters(in: .whitespaces)
        return value.flatMap { isSafeHost($0) ? $0 : nil } ?? defaultHost
    }
    public static func dest(_ defaults: UserDefaults = .standard) -> String {
        let value = defaults.string(forKey: destKey)?.trimmingCharacters(in: .whitespaces)
        return value.flatMap { isSafeDest($0) ? $0 : nil } ?? defaultDest
    }

    /// A plain hostname / Tailscale MagicDNS name — no shell metachars, no user@, no path. A bad stored
    /// value falls back to the default so a corrupted setting can never redirect the rsync target.
    static func isSafeHost(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 253 else { return false }
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-.")
        guard value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        // Must START and END alphanumeric — a leading '-' would let rsync parse "${DEST_HOST}:…" as an OPTION
        // (argument injection that silently disables the push), and a leading/trailing '.' is not a real host.
        let alnum = CharacterSet.alphanumerics
        guard let first = value.unicodeScalars.first, let last = value.unicodeScalars.last,
              alnum.contains(first), alnum.contains(last) else { return false }
        // Must be a Tailscale MagicDNS name (…​.ts.net). The relay is Tailscale-only (WireGuard-encrypted,
        // device-authenticated), so a non-`.ts.net` host would route personal transcripts over the open
        // internet. Enforcing the suffix makes "personal-tailnet-only" an ENFORCED boundary, not just the
        // default value's convention (review finding 4) — an overridden/tampered host that isn't on a
        // tailnet is rejected and falls back to the pinned default.
        guard value.lowercased().hasSuffix(".ts.net") else { return false }
        return true
    }

    /// A CONTAINED relative subdirectory on the server — never absolute (`/`), never `~`, never `..`, never
    /// dot-leading, only safe path chars. This is the real guard on `rsync --delete`'s blast radius: it can
    /// only ever prune inside `$HOME/<dest>` on the server, not the home dir or an arbitrary path.
    static func isSafeDest(_ value: String) -> Bool {
        guard !value.isEmpty, !value.hasPrefix("/"), !value.hasPrefix("~"), !value.hasPrefix("."),
              !value.hasPrefix("-"), !value.contains("..") else { return false }
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./")
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    public static var scriptURL: URL { home.appendingPathComponent("bin/callbrain-corpus-sync.sh") }
    public static var plistURL: URL { home.appendingPathComponent("Library/LaunchAgents/\(label).plist") }

    /// Write the helper script + LaunchAgent for `corpusFolder`, then (re)load it. Idempotent.
    public static func install(corpusFolder: URL, defaults: UserDefaults = .standard) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: scriptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        try Data(scriptBody(corpusFolder: corpusFolder, host: host(defaults), dest: dest(defaults)).utf8)
            .write(to: scriptURL, options: .atomic)
        // 0700, not 0755: the script reveals the corpus folder path + server host/dest — keep it
        // readable only by the founder, not any other local account that can traverse ~/bin (review finding 8).
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
        try Data(plistBody(corpusFolder: corpusFolder).utf8).write(to: plistURL, options: .atomic)

        // Reload: bootout (ignore "not loaded") then bootstrap the fresh plist. A failed bootstrap means the
        // agent isn't actually loaded — throw so the service surfaces it instead of silently "succeeding".
        _ = runLaunchctl(["bootout", domainTarget])
        let status = runLaunchctl(["bootstrap", guiDomain, plistURL.path])
        if status != 0 {
            throw NSError(domain: "CorpusSyncInstaller", code: Int(status), userInfo:
                [NSLocalizedDescriptionKey: "launchctl bootstrap failed (\(status)); the sync agent may not be loaded."])
        }
    }

    /// Unload + remove the LaunchAgent and script.
    public static func uninstall() {
        _ = runLaunchctl(["bootout", domainTarget])
        try? FileManager.default.removeItem(at: plistURL)
        try? FileManager.default.removeItem(at: scriptURL)
    }

    // MARK: - Pure generators (unit-tested)

    public static func scriptBody(corpusFolder: URL, host: String, dest: String) -> String {
        let path = corpusFolder.path
        let srcSlash = path.hasSuffix("/") ? path : path + "/"
        return """
        #!/bin/bash
        set -euo pipefail
        SRC=\(shellQuote(srcSlash))
        DEST_HOST=\(shellQuote(host))
        DEST_DIR=\(shellQuote(dest))
        SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)
        # SRC must be an ABSOLUTE path. A non-absolute value (e.g. one starting with '-') must never reach
        # rsync as a positional argument it could parse as an OPTION — defense-in-depth alongside the `--`
        # end-of-options marker below (review finding 2: rsync-argv/`-e` injection).
        case "$SRC" in /*) ;; *) echo "corpus source is not an absolute path; refusing"; exit 1;; esac
        # Source guard: never sync from a folder that isn't a provisioned Recap corpus — stops an empty
        # / half-provisioned source from letting `--delete` wipe the server.
        [ -f "${SRC}.callbrain-corpus" ] || { echo "no corpus marker at ${SRC}; skipping"; exit 0; }
        # Destination guard (mirror of the source marker): refuse a destructive `--delete` against a server
        # folder that already EXISTS but is NOT a Recap corpus (no `.callbrain-corpus` marker) — so a
        # mis-set/tampered dest can never prune the server's real Documents/Desktop/etc., and a dest that's
        # a symlink to an unrelated folder is caught too. A fresh/absent dest is fine: rsync --mkpath
        # creates it and the marker is pushed on this run. DEST_DIR is allow-list-validated (no shell
        # metachars, no ..), so it can't inject into the remote command.
        rc=0
        ssh "${SSH_OPTS[@]}" "$DEST_HOST" 'd="$HOME/'"${DEST_DIR}"'"; if [ -e "$d" ] && [ ! -e "$d/.callbrain-corpus" ]; then exit 9; fi' || rc=$?
        if [ "$rc" -eq 9 ]; then echo "dest ~/${DEST_DIR} exists but is not a Recap corpus; refusing --delete"; exit 1; fi
        if [ "$rc" -ne 0 ]; then echo "dest preflight ssh failed (rc=$rc); will retry next trigger"; exit "$rc"; fi
        # Use REAL GNU rsync (Homebrew), NOT macOS's /usr/bin/rsync (openrsync) — openrsync silently
        # reports success but writes NOTHING over ssh between two Macs. --rsync-path forces the server to
        # use its GNU rsync too. Both are on the standard Apple-Silicon Homebrew path.
        RSYNC=""
        for c in /opt/homebrew/bin/rsync /usr/local/bin/rsync; do [ -x "$c" ] && RSYNC="$c" && break; done
        [ -n "$RSYNC" ] || { echo "GNU rsync not installed — run: brew install rsync"; exit 1; }
        # No partial-transfer flag: rsync renames each file into place on completion, so the bot never
        # reads a half-written file. --mkpath auto-creates the dest folder on the server. `--` ends option
        # parsing so a hostile SRC can never be read as an rsync option.
        exec "$RSYNC" -a --delete --mkpath \\
          --rsync-path=/opt/homebrew/bin/rsync \\
          -e "ssh ${SSH_OPTS[*]}" \\
          -- "$SRC" "${DEST_HOST}:${DEST_DIR}/"
        """
    }

    public static func plistBody(corpusFolder: URL) -> String {
        let root = corpusFolder.path
        let calls = corpusFolder.appendingPathComponent("calls").path
        // Logs go to the user-private ~/Library/Logs (mode 700), NOT world-readable /tmp: rsync/ssh
        // error output can name corpus files (meeting titles) — those must not sit where any local
        // process can read them. ~/Library/Logs always exists, so launchd creates the files there.
        let outLog = home.appendingPathComponent("Library/Logs/callbrain-corpus-sync.out.log").path
        let errLog = home.appendingPathComponent("Library/Logs/callbrain-corpus-sync.err.log").path
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key><string>\(label)</string>
          <key>ProgramArguments</key>
          <array><string>\(xmlEscape(scriptURL.path))</string></array>
          <key>RunAtLoad</key><true/>
          <key>WatchPaths</key>
          <array>
            <string>\(xmlEscape(root))</string>
            <string>\(xmlEscape(calls))</string>
          </array>
          <key>StartInterval</key><integer>300</integer>
          <key>StandardOutPath</key><string>\(xmlEscape(outLog))</string>
          <key>StandardErrorPath</key><string>\(xmlEscape(errLog))</string>
        </dict>
        </plist>
        """
    }

    /// POSIX single-quote wrap (safe for any path/host/dest inside a bash double-quoted expansion `$SRC`).
    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func xmlEscape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    // MARK: - launchctl

    private static var guiDomain: String { "gui/\(getuid())" }
    private static var domainTarget: String { "gui/\(getuid())/\(label)" }

    @discardableResult
    private static func runLaunchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        do { try process.run(); process.waitUntilExit(); return process.terminationStatus }
        catch { return -1 }
    }
}
