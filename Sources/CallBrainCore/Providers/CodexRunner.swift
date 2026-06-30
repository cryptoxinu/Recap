import Foundation

/// Drives the Codex CLI (`codex exec`) as a stateless, sandboxed text endpoint over the user's ChatGPT
/// subscription (no API key) — the flip-side of `ClaudeRunner` (docs/ARCHITECTURE §5). The prompt is
/// piped on stdin (handles long RAG prompts past ARG_MAX); the final assistant message is captured via
/// `--output-last-message <file>` (clean, vs parsing the verbose session log). `-s read-only` +
/// `--skip-git-repo-check` keep it side-effect-free and injection-inert.
public actor CodexRunner: LLMProvider {
    public let executablePath: String
    public let sandboxDir: String
    /// The codex model (nil = codex's built-in default). The protocol's `model:` param is a Claude-centric
    /// hint and is IGNORED here (Codex would otherwise report a model it isn't using — gate MED).
    private let codexModel: String?
    public nonisolated let id: ProviderID = .codex

    /// Scrub API-key env → forces the CLI's subscription/OAuth auth (never a paid key).
    static let scrubbedEnv = ["OPENAI_API_KEY", "OPENAI_BASE_URL", "ANTHROPIC_API_KEY",
                              "ANTHROPIC_AUTH_TOKEN", "OPENAI_ORGANIZATION", "OPENAI_PROJECT"]

    public init(executablePath: String = "/opt/homebrew/bin/codex", sandboxDir: String, model: String? = nil) {
        self.executablePath = executablePath
        self.sandboxDir = sandboxDir
        self.codexModel = model
    }

    /// Hardened invocation (gate CRITICAL/HIGH): `-s read-only` (no writes, no network egress under the
    /// sandbox), `--ephemeral` (don't persist the private RAG prompt in a session log), and
    /// `--ignore-user-config` (don't load config.toml that could redirect to a paid API-key provider —
    /// auth still uses the CODEX_HOME subscription). Output captured to a private last-message file.
    static func baseArgs(cwd: String, outFile: String, model: String?) -> [String] {
        var a = ["exec", "-s", "read-only", "--skip-git-repo-check", "--ephemeral",
                 "--ignore-user-config", "--cd", cwd, "-o", outFile]
        if let model, !model.isEmpty { a += ["-m", model] }
        return a
    }

    public func complete(prompt: String, system: String? = nil,
                         model: String = "", timeout: TimeInterval = 120) async throws -> Completion {
        let text = try await runCapture(fullPrompt: Self.merge(system, prompt), extraArgs: [], timeout: timeout)
        return Completion(text: text, provider: .codex, model: codexModel ?? "codex", usage: TokenUsage(), costUSD: 0)
    }

    public func completeJSON(prompt: String, system: String?, schema: String,
                             model: String = "", timeout: TimeInterval = 180) async throws -> String {
        let schemaFile = Self.tempPath(ext: "json")
        try schema.write(toFile: schemaFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: schemaFile) }
        let raw = try await runCapture(fullPrompt: Self.merge(system, prompt),
                                       extraArgs: ["--output-schema", schemaFile], timeout: timeout)
        // The schema-constrained run returns JSON as the final message; tolerate fenced/extra prose.
        return ClaudeRunner.extractJSONValue(raw) ?? raw
    }

    // MARK: - spawn

    private func runCapture(fullPrompt: String, extraArgs: [String], timeout: TimeInterval) async throws -> String {
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            throw LLMError.notInstalled(executablePath)
        }
        let outFile = Self.tempPath(ext: "txt")
        defer { try? FileManager.default.removeItem(atPath: outFile) }

        let out = try await Subprocess.run(
            executable: executablePath,
            args: Self.baseArgs(cwd: sandboxDir, outFile: outFile, model: codexModel) + extraArgs,
            stdin: fullPrompt, cwd: sandboxDir, scrub: Self.scrubbedEnv, timeout: timeout)

        if out.exitCode != 0 {
            if Self.looksRateLimited(out.stderr) { throw LLMError.rateLimited(resetAt: nil) }
            throw LLMError.nonZeroExit(code: out.exitCode, stderr: String(out.stderr.prefix(500)))
        }
        // Prefer the clean last-message file; fall back to stdout if the runner didn't write it.
        let text = (try? String(contentsOfFile: outFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !text.isEmpty { return text }
        let fromStdout = Self.lastMessage(fromSession: out.stdout)
        guard !fromStdout.isEmpty else { throw LLMError.decodeFailed("codex: empty output") }
        return fromStdout
    }

    static func merge(_ system: String?, _ prompt: String) -> String {
        guard let system, !system.isEmpty else { return prompt }
        return "\(system)\n\n\(prompt)"
    }

    static func tempPath(ext: String) -> String {
        NSTemporaryDirectory() + "cb-codex-\(UUID().uuidString).\(ext)"
    }

    static func looksRateLimited(_ stderr: String) -> Bool {
        let s = stderr.lowercased()
        return s.contains("rate limit") || s.contains("rate-limit") || s.contains("429")
            || s.contains("quota") || s.contains("usage limit") || s.contains("too many requests")
    }

    /// Fallback parse of the verbose `codex exec` session log: the answer follows the last bare `codex`
    /// marker line, before the trailing `tokens used` footer.
    static func lastMessage(fromSession stdout: String) -> String {
        var lines = stdout.components(separatedBy: "\n")
        if let footer = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("tokens used") }) {
            lines = Array(lines[..<footer])
        }
        guard let marker = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "codex" }) else {
            return stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return lines[(marker + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
