import Foundation

/// Probes the live state of Recap's engines — the premium CLIs (`claude` / `codex`) and the local
/// Ollama stack (summary model + embedder) — so the Home cards can show what's actually wired up and
/// whether it's working. Every probe runs OFF the main thread; the result is cached and refreshed when a
/// status popover opens (never on the render/launch hot path).
@MainActor
@Observable
final class SystemStatus {
    struct Snapshot: Sendable, Equatable {
        var claudeOK = false
        var codexOK = false
        var ollamaOK = false
        var models: [String] = []       // installed Ollama model names (from /api/tags)
        var loaded = false              // a probe has completed at least once
    }
    private(set) var snap = Snapshot()
    private(set) var checking = false

    /// The exact executables the runners launch (ClaudeRunner / CodexRunner defaults) — so "available"
    /// means "the binary Recap will actually run is present + executable", not a generic PATH guess.
    nonisolated static let claudePath = "\(NSHomeDirectory())/.local/bin/claude"
    nonisolated static let codexPath = "/opt/homebrew/bin/codex"
    nonisolated static let ollamaBase = URL(string: "http://127.0.0.1:11434")!

    func refresh() async {
        checking = true; defer { checking = false }
        let (c, x) = await Task.detached {
            (FileManager.default.isExecutableFile(atPath: Self.claudePath),
             FileManager.default.isExecutableFile(atPath: Self.codexPath))
        }.value
        let models = await Self.ollamaModels()
        snap = Snapshot(claudeOK: c, codexOK: x, ollamaOK: models != nil, models: models ?? [], loaded: true)
    }

    /// True if an Ollama model matching `prefix` (e.g. "qwen2.5:3b", "nomic-embed-text") is installed.
    func hasModel(_ prefix: String) -> Bool {
        snap.models.contains { $0 == prefix || $0.hasPrefix(prefix) || $0.hasPrefix(prefix + ":") }
    }

    // MARK: - Local AI (Ollama) power control (in-app on/off + auto-recover)

    nonisolated static let ollamaBin = "/opt/homebrew/bin/ollama"

    /// Start the local Ollama server if it isn't running (the bundled Ollama.app if present, else the CLI's
    /// `ollama serve`). Idempotent + best-effort; detaches so it runs independently of Recap.
    nonisolated static func startOllama() {
        runShell("if [ -d /Applications/Ollama.app ]; then open -ga Ollama; " +
                 "else nohup \(ollamaBin) serve >/dev/null 2>&1 & fi")
    }

    /// Force-stop the local AI: unload any resident model, then stop the server — a true in-app "off" so
    /// nothing stays resident. Also unregisters the login-service so it doesn't respawn; a recording (or the
    /// Start button) brings it back.
    nonisolated static func stopOllama() {
        runShell("""
        for m in $(\(ollamaBin) ps 2>/dev/null | tail -n +2 | awk '{print $1}'); do \(ollamaBin) stop "$m" 2>/dev/null; done
        /opt/homebrew/bin/brew services stop ollama 2>/dev/null
        pkill -x ollama 2>/dev/null; pkill -f 'Ollama.app/Contents/MacOS' 2>/dev/null
        true
        """, wait: true)
    }

    /// Ensure the local AI is reachable; if not, start it and wait (bounded ~5s) for it to bind. Called at
    /// record-start so a manually-stopped engine AUTO-RECOVERS — a couple seconds' cost, never a silently
    /// broken recording (founder: kick on by itself in case I left it off).
    nonisolated static func ensureRunning() async {
        if await ollamaModels() != nil { return }
        startOllama()
        for _ in 0..<12 {
            try? await Task.sleep(for: .milliseconds(400))
            if await ollamaModels() != nil { return }
        }
    }

    nonisolated private static func runShell(_ script: String, wait: Bool = false) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", script]
        try? p.run()
        if wait { p.waitUntilExit() }
    }

    /// GET /api/tags → installed model names; nil if Ollama isn't reachable (short timeout so a stopped
    /// Ollama fails fast instead of hanging the popover).
    static func ollamaModels() async -> [String]? {
        var req = URLRequest(url: ollamaBase.appendingPathComponent("api/tags"))
        req.timeoutInterval = 2
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = root["models"] as? [[String: Any]] else { return nil }
        return arr.compactMap { $0["name"] as? String }
    }
}
