import Foundation

/// Drives the Codex CLI (`codex exec`) as a stateless, sandboxed text endpoint over the user's ChatGPT
/// subscription (no API key) — the flip-side of `ClaudeRunner` (docs/ARCHITECTURE §5). The prompt is
/// piped on stdin (handles long RAG prompts past ARG_MAX); the final assistant message is captured via
/// `--output-last-message <file>` (clean, vs parsing the verbose session log). `-s read-only` +
/// `--skip-git-repo-check` keep it side-effect-free and injection-inert.
public actor CodexRunner: LLMProvider, WebResearchProvider {
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
                 "--ignore-user-config",
                 "-c", "model_reasoning_effort=medium",   // balance quality with latency so a big RAG prompt doesn't blow the timeout → spurious "answered with Claude" fallback (audit)
                 "--cd", cwd, "-o", outFile]
        if let model, !model.isEmpty { a += ["-m", model] }
        return a
    }

    public func complete(prompt: String, system: String? = nil,
                         model: String = "", timeout: TimeInterval = 120) async throws -> Completion {
        let text = try await runCapture(fullPrompt: Self.merge(system, prompt), extraArgs: [], timeout: timeout)
        return Completion(text: text, provider: .codex, model: codexModel ?? "codex", usage: TokenUsage(), costUSD: 0)
    }

    /// Web-research call (user-initiated): enables Codex's native `web_search` tool (hosted, so it works
    /// under the read-only sandbox). Same scrubbed subscription auth; no shell/file writes.
    public func completeWithWeb(prompt: String, system: String? = nil,
                                model: String = "", timeout: TimeInterval = 240) async throws -> Completion {
        let text = try await runCapture(fullPrompt: Self.merge(system, prompt),
                                        extraArgs: ["-c", "tools.web_search=true"], timeout: timeout)
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

    /// Streamed Codex answer. Codex `exec --json` is item-level rather than true token streaming:
    /// completed `agent_message` items become `.delta` chunks, then the same `-o` last-message file used by
    /// buffered mode supplies the authoritative `.done` text. The subprocess lifecycle is the shared
    /// streaming one: stderr drain, inactivity timeout, and cancellation kills the child.
    public nonisolated func streamComplete(prompt: String, system: String?, model: String,
                                           timeout: TimeInterval) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            guard FileManager.default.isExecutableFile(atPath: executablePath) else {
                continuation.finish(throwing: LLMError.notInstalled(executablePath))
                return
            }

            let outFile = Self.tempPath(ext: "txt")
            let args = Self.baseArgs(cwd: sandboxDir, outFile: outFile, model: codexModel) + ["--json"]
            let chunks = Subprocess.stream(executable: executablePath, args: args,
                                           stdin: Self.merge(system, prompt), cwd: sandboxDir,
                                           scrub: Self.scrubbedEnv, inactivityTimeout: timeout)
            let task = Task {
                var lineBuffer = Data()
                var deltas: [String] = []
                do {
                    continuation.yield(.ready)
                    for try await chunk in chunks {
                        lineBuffer.append(chunk)
                        while let nl = lineBuffer.firstIndex(of: 0x0A) {
                            let line = lineBuffer.prefix(upTo: nl)
                            lineBuffer.removeSubrange(...nl)
                            guard !line.isEmpty else { continue }
                            if let delta = try Self.parseJSONStreamLine(Data(line)) {
                                deltas.append(delta)
                                continuation.yield(.delta(delta))
                            }
                        }
                    }
                    if !lineBuffer.isEmpty, let delta = try Self.parseJSONStreamLine(lineBuffer) {
                        deltas.append(delta)
                        continuation.yield(.delta(delta))
                    }

                    let fileText = (try? String(contentsOfFile: outFile, encoding: .utf8))?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let finalText = fileText.isEmpty ? deltas.joined().trimmingCharacters(in: .whitespacesAndNewlines) : fileText
                    guard !finalText.isEmpty else {
                        continuation.finish(throwing: LLMError.decodeFailed("codex: empty streamed output"))
                        return
                    }
                    continuation.yield(.done(Completion(text: finalText, provider: .codex,
                                                         model: codexModel ?? "codex",
                                                         usage: TokenUsage(), costUSD: 0)))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                try? FileManager.default.removeItem(atPath: outFile)
            }
        }
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

    /// Parse one `codex exec --json` event line. Codex currently emits completed assistant messages as
    /// item-level chunks (`item.completed` / `agent_message`), not token deltas. Error events are provider
    /// verdicts and must not be collapsed into decode failures.
    static func parseJSONStreamLine(_ line: Data) throws -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = obj["type"] as? String else { return nil }
        // Only TERMINAL failures are provider verdicts. A non-terminal `item.failed` (one tool/sub-item
        // failing mid-turn) must NOT abort an otherwise-successful stream (audit LOW).
        let isTerminalFailure = type.hasSuffix(".failed") && type != "item.failed"
        if obj["is_error"] as? Bool == true || type == "error" || isTerminalFailure {
            throw LLMError.providerError(subtype: (obj["subtype"] as? String) ?? type,
                                         detail: errorDetail(from: obj))
        }

        if type == "item.completed", let item = obj["item"] as? [String: Any],
           isAgentMessage(item), let text = textContent(from: item), !text.isEmpty {
            return text
        }
        if isAgentMessage(obj), let text = textContent(from: obj), !text.isEmpty {
            return text
        }
        return nil
    }

    private static func isAgentMessage(_ obj: [String: Any]) -> Bool {
        let type = obj["type"] as? String
        if type == "agent_message" || type == "assistant_message" { return true }
        return type == "message" && obj["role"] as? String == "assistant"
    }

    private static func textContent(from obj: [String: Any]) -> String? {
        for key in ["text", "message", "content"] {
            if let text = stringContent(from: obj[key]), !text.isEmpty {
                return text
            }
        }
        return nil
    }

    private static func stringContent(from value: Any?) -> String? {
        switch value {
        case let text as String:
            return text
        case let parts as [Any]:
            let strings = parts.compactMap { stringContent(from: $0) }
            return strings.isEmpty ? nil : strings.joined()
        case let dict as [String: Any]:
            for key in ["text", "content", "message", "value"] {
                if let text = stringContent(from: dict[key]), !text.isEmpty { return text }
            }
            return nil
        default:
            return nil
        }
    }

    private static func errorDetail(from obj: [String: Any]) -> String {
        if let message = obj["message"] as? String { return message }
        if let detail = obj["detail"] as? String { return detail }
        if let error = obj["error"] as? String { return error }
        if let error = obj["error"] as? [String: Any] {
            return (error["message"] as? String) ?? "\(error)"
        }
        return obj["type"] as? String ?? "codex stream error"
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
