import Testing
import Foundation
@testable import CallBrainCore

@Suite("ClaudeRunner")
struct ClaudeRunnerTests {

    // Trimmed copy of a REAL `claude -p --output-format json` envelope captured on this machine
    // (docs/research/cli-envelopes/claude-answer.json). Note the two models: an internal haiku
    // helper (12 output tokens) and the answering sonnet (5) — the parser must pick sonnet.
    static let envelope = """
    {"type":"result","subtype":"success","is_error":false,"result":"pong","stop_reason":"end_turn",
     "total_cost_usd":0.0080543,
     "usage":{"input_tokens":3,"output_tokens":5,"cache_read_input_tokens":2131,"cache_creation_input_tokens":1127},
     "modelUsage":{
       "claude-haiku-4-5-20251001":{"inputTokens":509,"outputTokens":12,"costUSD":0.000569},
       "claude-sonnet-4-6":{"inputTokens":3,"outputTokens":5,"costUSD":0.0074853}}}
    """

    @Test("answerArgs builds the verified tool-stripped, subscription-safe command")
    func argsCore() {
        let a = ClaudeRunner.answerArgs(model: "sonnet", system: "You are CallBrain.")
        #expect(a.contains("-p"))
        #expect(a.contains("--safe-mode"))                 // keeps OAuth, strips hooks/MCP/CLAUDE.md
        #expect(a.contains("--strict-mcp-config"))
        #expect(a.contains("--output-format"))
        #expect(a.contains("json"))
        // tool-stripped: "--tools" immediately followed by "" (no tools to call → injection-inert)
        let i = a.firstIndex(of: "--tools")!
        #expect(a[a.index(after: i)] == "")
        #expect(a.contains("--system-prompt"))
        #expect(a.contains("You are CallBrain."))
        #expect(!a.contains("--bare"))                     // never (breaks subscription auth)
        #expect(!a.contains("--dangerously-skip-permissions"))
    }

    @Test("answerArgs omits --system-prompt when there is no system text")
    func argsNoSystem() {
        let a = ClaudeRunner.answerArgs(model: "opus", system: nil)
        #expect(!a.contains("--system-prompt"))
        #expect(a.contains("opus"))
    }

    @Test("researchArgs enables ONLY WebSearch+WebFetch + keeps --safe-mode (hooks/config off; SME H2)")
    func researchArgsWebOnly() {
        let a = ClaudeRunner.researchArgs(model: "opus", system: "sys")
        #expect(a.contains("WebSearch") && a.contains("WebFetch"))
        #expect(a.contains("--allowedTools"))                      // auto-approve → no headless prompt hang
        #expect(a.contains("--safe-mode"))                         // hooks/CLAUDE.md/skills/MCP off (verified web still works)
        #expect(!a.contains("Bash") && !a.contains("Write") && !a.contains("Edit"))  // no code/file execution
        #expect(!a.contains("--dangerously-skip-permissions"))
        #expect(a.contains("--strict-mcp-config") && a.contains("--no-session-persistence"))
    }

    @Test("parseEnvelope picks the answering model (not the helper) + correct tokens/cost")
    func parse() throws {
        let c = try ClaudeRunner.parseEnvelope(Data(Self.envelope.utf8), requestedModel: "sonnet")
        #expect(c.text == "pong")
        #expect(c.provider == .claude)
        #expect(c.model == "claude-sonnet-4-6")            // matched by output tokens (5), not haiku (12)
        #expect(c.usage.outputTokens == 5)
        #expect(c.usage.inputTokens == 3)
        #expect(c.usage.cacheReadTokens == 2131)
        #expect(abs(c.costUSD - 0.0080543) < 1e-9)         // total_cost_usd
        #expect(c.stopReason == "end_turn")
    }

    @Test("parseEnvelope throws on an error envelope (never a silent empty answer)")
    func parseError() {
        let bad = #"{"type":"result","subtype":"error_max_turns","is_error":true,"result":"hit a limit"}"#
        #expect(throws: LLMError.self) {
            try ClaudeRunner.parseEnvelope(Data(bad.utf8), requestedModel: "sonnet")
        }
    }

    @Test("parseEnvelope rejects malformed JSON")
    func parseMalformed() {
        #expect(throws: LLMError.self) {
            try ClaudeRunner.parseEnvelope(Data("not json".utf8), requestedModel: "sonnet")
        }
    }

    @Test("extractJSONValue is string-aware — a brace inside a JSON string doesn't truncate it (C MED)")
    func extractJSONStringAware() {
        // The `}` inside the note value used to close the object early.
        let s = "prefix {\"note\":\"saw } and [brackets] in transcript\",\"ok\":true} suffix"
        let out = ClaudeRunner.extractJSONValue(s)
        #expect(out == "{\"note\":\"saw } and [brackets] in transcript\",\"ok\":true}")
        // And it round-trips as valid JSON.
        #expect((try? JSONSerialization.jsonObject(with: Data((out ?? "").utf8))) != nil)
    }

    @Test("extractJSONValue honors escaped quotes inside strings")
    func extractJSONEscapes() {
        let s = #"{"q":"he said \"hi\" then }"}"#
        #expect(ClaudeRunner.extractJSONValue(s) == s)
    }

    @Test("rate-limit detection reads the stderr signal")
    func rateLimit() {
        #expect(ClaudeRunner.looksRateLimited("Error: usage limit reached") == true)
        #expect(ClaudeRunner.looksRateLimited("HTTP 429 too many requests") == true)
        #expect(ClaudeRunner.looksRateLimited("normal output") == false)
    }

    // Opt-in live smoke: actually spawns `claude -p` over your subscription. Run with:
    //   CALLBRAIN_LIVE=1 swift test --filter ClaudeRunner
    @Test("live claude smoke", .enabled(if: ProcessInfo.processInfo.environment["CALLBRAIN_LIVE"] == "1"))
    func liveSmoke() async throws {
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent("cb-sandbox").path
        try? FileManager.default.createDirectory(atPath: sandbox, withIntermediateDirectories: true)
        let runner = ClaudeRunner(sandboxDir: sandbox)
        let c = try await runner.complete(prompt: "Reply with exactly the single word: pong",
                                          model: "sonnet", timeout: 90)
        #expect(!c.text.isEmpty)
        #expect(c.provider == .claude)
    }

    @Test("Subprocess.isSecretEnvKey strips credential-bearing env vars, keeps benign ones (audit MED)")
    func secretEnvScrub() {
        // Credentials + provider-redirect vars must NOT reach the spawned CLI.
        for k in ["ANTHROPIC_API_KEY", "ANTHROPIC_BASE_URL", "OPENAI_API_KEY", "GITHUB_TOKEN", "HF_TOKEN",
                  "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "GOOGLE_APPLICATION_CREDENTIALS",
                  "SOME_SERVICE_SECRET", "DB_PASSWORD"] {
            #expect(Subprocess.isSecretEnvKey(k), "expected \(k) to be scrubbed")
        }
        // Vars the CLI legitimately needs must pass through.
        for k in ["PATH", "HOME", "USER", "LANG", "TMPDIR", "CODEX_HOME", "SHELL", "TERM"] {
            #expect(!Subprocess.isSecretEnvKey(k), "expected \(k) to be kept")
        }
    }

    @Test("subprocess environment repairs GUI PATH so node-backed Codex can launch")
    func subprocessEnvironmentRepairsGUIPath() {
        let env = Subprocess.makeEnvironment(
            base: ["HOME": "/Users/z", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "OPENAI_API_KEY": "secret"],
            scrub: ["OPENAI_API_KEY"])
        #expect(env["OPENAI_API_KEY"] == nil)
        let parts = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        #expect(parts.contains("/opt/homebrew/bin"))
        #expect(parts.contains("/usr/bin"))
        #expect(parts.first == "/opt/homebrew/bin")
    }
}
