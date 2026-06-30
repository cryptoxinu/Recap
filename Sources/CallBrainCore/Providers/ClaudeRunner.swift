import Foundation

/// Drives the Claude Code CLI (`claude -p`) as a stateless, tool-stripped, sandboxed text endpoint
/// over the user's subscription (no API key). Command lines verified live (docs/ARCHITECTURE.md §5.1).
///
/// Command-building and envelope-parsing are pure static funcs (unit-tested against a captured real
/// envelope); only `complete` spawns the subprocess.
public actor ClaudeRunner: LLMProvider {
    public let executablePath: String
    public let sandboxDir: String
    public nonisolated let id: ProviderID = .claude

    /// Env vars scrubbed from the child → forces subscription/OAuth auth instead of a paid API key.
    static let scrubbedEnv = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "OPENAI_API_KEY", "OPENAI_BASE_URL"]

    public init(executablePath: String = "\(NSHomeDirectory())/.local/bin/claude",
                sandboxDir: String) {
        self.executablePath = executablePath
        self.sandboxDir = sandboxDir
    }

    // MARK: - pure: argument construction

    /// Argv for a grounded answer (RAG) call. Tool-stripped + safe-mode keep OAuth but disable
    /// hooks/MCP/CLAUDE.md/skills and all built-in tools (so injected transcript text has nothing to call).
    static func answerArgs(model: String, system: String?) -> [String] {
        var a = ["-p",
                 "--model", model,
                 "--safe-mode",
                 "--tools", "",
                 "--strict-mcp-config",
                 "--no-session-persistence",
                 "--permission-mode", "default",
                 "--output-format", "json"]
        if let system, !system.isEmpty { a += ["--system-prompt", system] }
        return a
    }

    // MARK: - pure: envelope parsing

    private struct Envelope: Decodable {
        let type: String?
        let subtype: String?
        let is_error: Bool?
        let result: String?
        let stop_reason: String?
        let total_cost_usd: Double?
        let usage: Usage?
        let modelUsage: [String: ModelUsage]?
        struct Usage: Decodable {
            let input_tokens: Int?
            let output_tokens: Int?
            let cache_read_input_tokens: Int?
            let cache_creation_input_tokens: Int?
        }
        struct ModelUsage: Decodable {
            let inputTokens: Int?
            let outputTokens: Int?
            let costUSD: Double?
        }
    }

    /// Decode `claude --output-format json` into a `Completion`. Throws `providerError` on an error
    /// envelope and `decodeFailed` on a missing result.
    static func parseEnvelope(_ data: Data, requestedModel: String) throws -> Completion {
        let env: Envelope
        do { env = try JSONDecoder().decode(Envelope.self, from: data) }
        catch { throw LLMError.decodeFailed("claude envelope: \(error)") }

        if env.is_error == true {
            throw LLMError.providerError(subtype: env.subtype ?? "error",
                                         detail: env.result ?? env.type ?? "unknown")
        }
        guard let text = env.result else { throw LLMError.decodeFailed("claude envelope missing .result") }

        let usage = TokenUsage(
            inputTokens: env.usage?.input_tokens ?? 0,
            outputTokens: env.usage?.output_tokens ?? 0,
            cacheReadTokens: env.usage?.cache_read_input_tokens ?? 0,
            cacheCreationTokens: env.usage?.cache_creation_input_tokens ?? 0)

        // The envelope can list several models (e.g. an internal haiku helper + the answering model).
        // Pick the one whose output-token count matches the top-level answer turn; else a name match.
        let model = pickModel(env.modelUsage, requested: requestedModel, answerOutputTokens: usage.outputTokens)
        let cost = env.total_cost_usd ?? (env.modelUsage?.values.compactMap(\.costUSD).reduce(0, +) ?? 0)

        return Completion(text: text, provider: .claude, model: model, usage: usage,
                          costUSD: cost, stopReason: env.stop_reason)
    }

    private static func pickModel(_ mu: [String: Envelope.ModelUsage]?, requested: String,
                                  answerOutputTokens: Int) -> String {
        guard let mu, !mu.isEmpty else { return requested }
        if answerOutputTokens > 0,
           let m = mu.first(where: { $0.value.outputTokens == answerOutputTokens })?.key { return m }
        if let m = mu.keys.first(where: { $0.contains(requested) }) { return m }
        return mu.max(by: { ($0.value.outputTokens ?? 0) < ($1.value.outputTokens ?? 0) })?.key ?? requested
    }

    static func looksRateLimited(_ stderr: String) -> Bool {
        let s = stderr.lowercased()
        return s.contains("rate limit") || s.contains("rate-limit") || s.contains("429")
            || s.contains("quota") || s.contains("usage limit")
    }

    // MARK: - live: spawn

    /// Run a grounded answer call. `prompt` (system rules already applied via `system`) is piped on stdin.
    public func complete(prompt: String, system: String? = nil,
                         model: String = "sonnet", timeout: TimeInterval = 120) async throws -> Completion {
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            throw LLMError.notInstalled(executablePath)
        }
        let out = try await Subprocess.run(
            executable: executablePath,
            args: Self.answerArgs(model: model, system: system),
            stdin: prompt,
            cwd: sandboxDir,
            scrub: Self.scrubbedEnv,
            timeout: timeout)

        if out.exitCode != 0 {
            if Self.looksRateLimited(out.stderr) { throw LLMError.rateLimited(resetAt: nil) }
            throw LLMError.nonZeroExit(code: out.exitCode, stderr: String(out.stderr.prefix(500)))
        }
        return try Self.parseEnvelope(Data(out.stdout.utf8), requestedModel: model)
    }

    /// Structured extraction: returns the model's JSON output as a STRING (Sendable across the actor
    /// boundary; the caller parses it). Uses `--json-schema` to constrain the output.
    public func completeJSON(prompt: String, system: String?, schema: String,
                             model: String = "sonnet", timeout: TimeInterval = 180) async throws -> String {
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            throw LLMError.notInstalled(executablePath)
        }
        let out = try await Subprocess.run(
            executable: executablePath,
            args: Self.answerArgs(model: model, system: system) + ["--json-schema", schema],
            stdin: prompt, cwd: sandboxDir, scrub: Self.scrubbedEnv, timeout: timeout)
        if out.exitCode != 0 {
            if Self.looksRateLimited(out.stderr) { throw LLMError.rateLimited(resetAt: nil) }
            throw LLMError.nonZeroExit(code: out.exitCode, stderr: String(out.stderr.prefix(500)))
        }
        return try Self.extractStructuredJSON(out.stdout)
    }

    /// Pull the JSON payload out of a `claude --output-format json --json-schema` envelope: prefer the
    /// `structured_output` object; otherwise extract the first balanced JSON value from `.result`.
    static func extractStructuredJSON(_ stdout: String) throws -> String {
        guard let data = stdout.data(using: .utf8),
              let env = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMError.decodeFailed("claude json: envelope not parseable")
        }
        if env["is_error"] as? Bool == true {
            throw LLMError.providerError(subtype: env["subtype"] as? String ?? "error",
                                         detail: env["result"] as? String ?? "")
        }
        if let so = env["structured_output"], JSONSerialization.isValidJSONObject(so),
           let d = try? JSONSerialization.data(withJSONObject: so) {
            return String(decoding: d, as: UTF8.self)
        }
        if let result = env["result"] as? String, let json = extractJSONValue(result) {
            return json
        }
        throw LLMError.decodeFailed("claude json: no structured_output or JSON found in result")
    }

    /// First balanced `{…}`/`[…]` value in a string (after stripping ``` fences). Good enough for
    /// model output; the `--json-schema` path normally returns clean `structured_output` anyway.
    static func extractJSONValue(_ s: String) -> String? {
        let t = s.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
        guard let start = t.firstIndex(where: { $0 == "{" || $0 == "[" }) else { return nil }
        let open = t[start]
        let close: Character = (open == "{") ? "}" : "]"
        var depth = 0
        var i = start
        while i < t.endIndex {
            let c = t[i]
            if c == open { depth += 1 } else if c == close {
                depth -= 1
                if depth == 0 { return String(t[start...i]) }
            }
            i = t.index(after: i)
        }
        return nil
    }
}
