import Testing
import Foundation
@testable import CallBrainAppCore

/// B6 — the rsync/LaunchAgent generators. These are security-sensitive (shell quoting, `--delete` safety),
/// so the pure body-generation is locked here; the file-write + launchctl I/O is founder-side.
@Suite("Corpus sync installer")
struct CorpusSyncInstallerTests {

    @Test("shellQuote wraps in single quotes and escapes embedded quotes")
    func quote() {
        #expect(CorpusSyncInstaller.shellQuote("plain") == "'plain'")
        #expect(CorpusSyncInstaller.shellQuote("a'b") == "'a'\\''b'")
        #expect(CorpusSyncInstaller.shellQuote("/Users/z/My Corpus") == "'/Users/z/My Corpus'")
    }

    @Test("scriptBody: marker guard, --delete-safe flags, single-quoted paths, trailing slash, openrsync-safe")
    func script() {
        let body = CorpusSyncInstaller.scriptBody(
            corpusFolder: URL(fileURLWithPath: "/Users/z/Library/Application Support/CallBrain/corpus"),
            host: "test-mac.tailnet0.ts.net", dest: "callbrain-corpus")
        #expect(body.hasPrefix("#!/bin/bash\nset -euo pipefail\n"))
        #expect(body.contains("SRC='/Users/z/Library/Application Support/CallBrain/corpus/'")) // quoted + trailing /
        #expect(body.contains("DEST_HOST='test-mac.tailnet0.ts.net'"))
        #expect(body.contains("DEST_DIR='callbrain-corpus'"))
        #expect(body.contains("[ -f \"${SRC}.callbrain-corpus\" ]")) // source marker guard before --delete
        #expect(body.contains("case \"$SRC\" in /*)"))               // SRC must be absolute (argv-injection guard)
        #expect(body.contains("-a --delete --mkpath"))
        #expect(body.contains("-- \"$SRC\""))                        // `--` ends option parsing before positionals
        // Destination marker preflight: refuse --delete against a non-CallBrain server folder.
        #expect(body.contains(".callbrain-corpus\" ]; then exit 9"))
        #expect(body.contains("refusing --delete"))
        // MUST use real GNU rsync (Homebrew), NOT macOS openrsync (which silently writes nothing over ssh),
        // and force the server to GNU rsync too.
        #expect(body.contains("/opt/homebrew/bin/rsync"))
        #expect(body.contains("--rsync-path=/opt/homebrew/bin/rsync"))
        #expect(!body.contains("--partial")) // rename-on-complete so the bot never reads a partial
        #expect(body.contains("BatchMode=yes"))
        #expect(!body.contains("--delay-updates"))
        #expect(!body.contains(" -z"))
    }

    @Test("dest/host validation rejects path-escape + shell-metachar values (contains --delete blast radius)")
    func destHostValidation() {
        // Safe
        #expect(CorpusSyncInstaller.isSafeDest("callbrain-corpus"))
        #expect(CorpusSyncInstaller.isSafeDest("sub/dir_1.2"))
        // Host MUST be a Tailscale MagicDNS name — the relay is Tailscale-only (review finding 4).
        #expect(CorpusSyncInstaller.isSafeHost("test-mac.tailnet0.ts.net"))
        #expect(CorpusSyncInstaller.isSafeHost("host.tail36b615.ts.net"))
        // Unsafe dest → would let --delete escape the intended dir (incl. leading '-')
        for bad in ["", "/", "/etc", "~", "~/x", ".", "..", "../up", "a/../b", "a b", "a;rm -rf", "a$(x)", "a`x`", "a\nb", "-rf"] {
            #expect(!CorpusSyncInstaller.isSafeDest(bad), "\(bad) should be rejected")
        }
        // Unsafe host — leading '-' (rsync option injection), leading/trailing '.', AND any non-Tailscale
        // host (a bare name or a public domain would route transcripts off the tailnet).
        for bad in ["", "a b", "a;b", "user@host", "a/b", "a`x`", "-e", "-rsh=x", ".host", "host.",
                    "bare-hostname", "evil-vps.example.net", "google.com"] {
            #expect(!CorpusSyncInstaller.isSafeHost(bad), "\(bad) should be rejected")
        }
        // A bad UserDefaults value falls back to the safe default.
        let defaults = UserDefaults(suiteName: "cb-sync-bad-\(UUID().uuidString)")!
        defaults.set("../../etc", forKey: CorpusSyncInstaller.destKey)
        defaults.set("evil;rm", forKey: CorpusSyncInstaller.hostKey)
        #expect(CorpusSyncInstaller.dest(defaults) == "callbrain-corpus")
        #expect(CorpusSyncInstaller.host(defaults) == "your-server.ts.net")
    }

    @Test("the generated script is valid bash")
    func scriptValidBash() throws {
        let body = CorpusSyncInstaller.scriptBody(corpusFolder: URL(fileURLWithPath: "/tmp/x"),
                                                  host: "h", dest: "d")
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("cb-sync-\(UUID()).sh")
        try Data(body.utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-n", tmp.path]
        try process.run(); process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    @Test("plistBody: valid parseable plist, WatchPaths root+calls, 5-min interval, one-shot (not KeepAlive)")
    func plist() {
        let body = CorpusSyncInstaller.plistBody(corpusFolder: URL(fileURLWithPath: "/Users/z/corpus"))
        #expect(body.contains("<string>com.callbrain.corpus-sync</string>"))
        #expect(body.contains("<string>/Users/z/corpus</string>"))
        #expect(body.contains("<string>/Users/z/corpus/calls</string>"))
        #expect(body.contains("<key>StartInterval</key><integer>300</integer>"))
        #expect(!body.contains("KeepAlive"))
        // Logs live in the user-private ~/Library/Logs, never world-readable /tmp (transcript filenames
        // can appear in rsync/ssh error output).
        #expect(body.contains("Library/Logs/callbrain-corpus-sync.out.log"))
        #expect(body.contains("Library/Logs/callbrain-corpus-sync.err.log"))
        #expect(!body.contains("/tmp/callbrain-corpus-sync"))
        #expect((try? PropertyListSerialization.propertyList(from: Data(body.utf8), format: nil)) != nil)
    }

    @Test("host/dest default when unset and honor a UserDefaults override")
    func hostDest() throws {
        let defaults = try #require(UserDefaults(suiteName: "cb-sync-test-\(UUID().uuidString)"))
        #expect(CorpusSyncInstaller.host(defaults) == "your-server.ts.net")
        #expect(CorpusSyncInstaller.dest(defaults) == "callbrain-corpus")
        // A valid Tailscale override is honored…
        defaults.set("other-mac.tailnet0.ts.net", forKey: CorpusSyncInstaller.hostKey)
        #expect(CorpusSyncInstaller.host(defaults) == "other-mac.tailnet0.ts.net")
        // …but a non-Tailscale override is rejected and falls back to the pinned default (finding 4).
        defaults.set("evil-vps.example.net", forKey: CorpusSyncInstaller.hostKey)
        #expect(CorpusSyncInstaller.host(defaults) == "your-server.ts.net")
    }
}
