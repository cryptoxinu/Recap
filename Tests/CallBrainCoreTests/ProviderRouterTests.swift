import Testing
import Foundation
@testable import CallBrainCore

/// A scriptable provider: each call runs the next behavior.
private actor StubProvider: LLMProvider {
    nonisolated let id: ProviderID
    private var script: [Result<String, LLMError>]
    init(id: ProviderID, _ script: [Result<String, LLMError>]) { self.id = id; self.script = script }
    private func next() throws -> String {
        guard !script.isEmpty else { throw LLMError.decodeFailed("script empty") }
        switch script.removeFirst() { case .success(let s): return s; case .failure(let e): throw e }
    }
    func complete(prompt: String, system: String?, model: String, timeout: TimeInterval) async throws -> Completion {
        Completion(text: try next(), provider: id, model: model, usage: TokenUsage(), costUSD: 0)
    }
    func completeJSON(prompt: String, system: String?, schema: String, model: String, timeout: TimeInterval) async throws -> String {
        try next()
    }
}

@Suite("ProviderRouter (flip + transparent fallback)")
struct ProviderRouterTests {

    @Test("primary answers → used, no fallback")
    func primaryAnswers() async throws {
        let router = ProviderRouter(claude: StubProvider(id: .claude, [.success("from claude")]),
                                    codex: StubProvider(id: .codex, [.success("from codex")]),
                                    primary: .claude)
        let c = try await router.complete(prompt: "hi", system: nil, model: "m", timeout: 5)
        #expect(c.text == "from claude")
        #expect(c.provider == .claude)
        #expect(await router.lastUsed == .claude)
        #expect(await router.lastFellBack == false)
    }

    @Test("primary rate-limited → transparent fallback to the other")
    func fallbackOnRateLimit() async throws {
        let router = ProviderRouter(claude: StubProvider(id: .claude, [.failure(.rateLimited(resetAt: nil))]),
                                    codex: StubProvider(id: .codex, [.success("codex saved it")]),
                                    primary: .claude)
        let c = try await router.complete(prompt: "hi", system: nil, model: "m", timeout: 5)
        #expect(c.text == "codex saved it")
        #expect(c.provider == .codex)
        #expect(await router.lastFellBack == true)
    }

    @Test("flip changes who answers first")
    func flip() async throws {
        let router = ProviderRouter(claude: StubProvider(id: .claude, [.success("C")]),
                                    codex: StubProvider(id: .codex, [.success("X")]),
                                    primary: .claude)
        router.setPrimary(.codex)   // synchronous (lock-guarded)
        let c = try await router.complete(prompt: "hi", system: nil, model: "m", timeout: 5)
        #expect(c.provider == .codex)
    }

    @Test("a TRANSIENT primary error (nonZeroExit) falls back to the other subscription (robustness — 2026-07-01)")
    func fallbackOnTransientError() async throws {
        // A CLI hiccup (nonzero exit, undecodable output, blip) now falls back — it shouldn't dead-end as
        // "Couldn't reach the AI engine" when the other subscription would answer.
        let router = ProviderRouter(claude: StubProvider(id: .claude, [.failure(.nonZeroExit(code: 1, stderr: "blip"))]),
                                    codex: StubProvider(id: .codex, [.success("codex answered")]),
                                    primary: .claude)
        let c = try await router.complete(prompt: "hi", system: nil, model: "m", timeout: 5)
        #expect(c.text == "codex answered")
        #expect(c.provider == .codex)
        #expect(await router.lastFellBack == true)
    }

    @Test("a DETERMINISTIC bad-request (.providerError) does NOT burn a second subscription call")
    func noFallbackOnProviderError() async throws {
        // The CLI ran and reported a real error envelope — the other CLI fails identically, so don't retry.
        let router = ProviderRouter(claude: StubProvider(id: .claude, [.failure(.providerError(subtype: "bad", detail: "nope"))]),
                                    codex: StubProvider(id: .codex, [.success("should NOT be used")]),
                                    primary: .claude)
        await #expect(throws: LLMError.self) { _ = try await router.complete(prompt: "hi", system: nil, model: "m", timeout: 5) }
    }

    @Test("both unavailable → allProvidersFailed")
    func bothDown() async throws {
        let router = ProviderRouter(claude: StubProvider(id: .claude, [.failure(.rateLimited(resetAt: nil))]),
                                    codex: StubProvider(id: .codex, [.failure(.notInstalled("/x"))]),
                                    primary: .claude)
        await #expect(throws: LLMError.self) { _ = try await router.complete(prompt: "hi", system: nil, model: "m", timeout: 5) }
    }
}

@Suite("CodexRunner (pure helpers)")
struct CodexRunnerTests {
    @Test("merge prepends system")
    func merge() {
        #expect(CodexRunner.merge(nil, "p") == "p")
        #expect(CodexRunner.merge("sys", "p") == "sys\n\np")
    }
    @Test("lastMessage extracts the answer from a codex session log")
    func lastMessage() {
        let log = """
        codex
        thinking about it
        codex
        The answer is 42.
        tokens used
        1234
        """
        #expect(CodexRunner.lastMessage(fromSession: log) == "The answer is 42.")
    }
    @Test("rate-limit detection")
    func rateLimit() {
        #expect(CodexRunner.looksRateLimited("Error: 429 Too Many Requests"))
        #expect(CodexRunner.looksRateLimited("you hit your usage limit"))
        #expect(!CodexRunner.looksRateLimited("normal output"))
    }

    @Test("hardened args: ephemeral + ignore-user-config + read-only sandbox (gate CRITICAL/HIGH)")
    func hardenedArgs() {
        let a = CodexRunner.baseArgs(cwd: "/tmp/x", outFile: "/tmp/o", model: "gpt-5-codex")
        #expect(a.contains("--ephemeral"))            // don't persist the RAG prompt
        #expect(a.contains("--ignore-user-config"))   // no config redirect to an API-key provider
        #expect(a.contains("read-only"))              // no writes / no network egress
        #expect(a.contains("model_reasoning_effort=medium"))  // balance quality/latency so big prompts don't timeout → spurious fallback
        #expect(a.contains("-m") && a.contains("gpt-5-codex"))
    }

    @Test("LIVE: codex answers a simple prompt",
          .enabled(if: ProcessInfo.processInfo.environment["CALLBRAIN_LIVE"] == "1"))
    func liveCodex() async throws {
        let sandbox = NSTemporaryDirectory() + "cb-codex-live"
        try? FileManager.default.createDirectory(atPath: sandbox, withIntermediateDirectories: true)
        let codex = CodexRunner(sandboxDir: sandbox)
        let c = try await codex.complete(prompt: "Reply with exactly the word PONG and nothing else.",
                                         system: "You are terse.", model: "gpt-5-codex", timeout: 90)
        #expect(c.provider == .codex)
        #expect(c.text.uppercased().contains("PONG"))
        print("LIVE CODEX: \(c.text)")
    }
}
