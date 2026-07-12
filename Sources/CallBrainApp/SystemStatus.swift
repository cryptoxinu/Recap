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
