import Foundation

/// Routes generation across the user's two CLI subscriptions (Phase 5): a `primary` provider the user
/// flips in Settings, with **transparent fallback** to the other on a rate-limit / unavailable / timeout
/// (so the founder "never thinks about quotas"). A genuine provider error (bad request) is NOT retried on
/// the other — only availability failures fall back. The answering provider is carried on `Completion`.
public actor ProviderRouter: LLMProvider, WebResearchProvider {
    public nonisolated let id: ProviderID = .claude   // nominal; consumers read Completion.provider
    private let claude: any LLMProvider
    private let codex: any LLMProvider
    /// Lock-guarded so a Settings flip is visible to the very next Ask immediately + synchronously,
    /// with no actor-hop ordering race (Codex P5 gate LOW).
    private let primaryBox = PrimaryBox()

    public private(set) var lastUsed: ProviderID?
    public private(set) var lastFellBack = false

    public init(claude: any LLMProvider, codex: any LLMProvider, primary: ProviderID = .claude) {
        self.claude = claude; self.codex = codex
        primaryBox.set((primary == .codex) ? .codex : .claude)
    }

    public nonisolated func setPrimary(_ p: ProviderID) { primaryBox.set((p == .codex) ? .codex : .claude) }
    public nonisolated func currentPrimary() -> ProviderID { primaryBox.value }

    private var ordered: [any LLMProvider] { primaryBox.value == .codex ? [codex, claude] : [claude, codex] }

    public func complete(prompt: String, system: String?, model: String,
                         timeout: TimeInterval) async throws -> Completion {
        try await route { try await $0.complete(prompt: prompt, system: system, model: model, timeout: timeout) }
    }

    public func completeJSON(prompt: String, system: String?, schema: String, model: String,
                             timeout: TimeInterval) async throws -> String {
        try await route { try await $0.completeJSON(prompt: prompt, system: system, schema: schema, model: model, timeout: timeout) }
    }

    /// Web research routed to the selected provider (Claude or Codex — both can search the web), with the
    /// same transparent fallback to the other on an availability failure.
    public func completeWithWeb(prompt: String, system: String?, model: String,
                                timeout: TimeInterval) async throws -> Completion {
        try await route { provider in
            guard let web = provider as? any WebResearchProvider else {
                throw LLMError.notInstalled("web research unavailable for \(provider.id)")
            }
            return try await web.completeWithWeb(prompt: prompt, system: system, model: model, timeout: timeout)
        }
    }

    /// Streamed generation with fallback ONLY before the first delta (Task 3.2 S4): once tokens
    /// have reached the user, silently swapping engines mid-answer would splice two different
    /// answers together — a mid-stream failure surfaces honestly instead. Same cancellation
    /// guard as route(): a Stop must never spawn the second CLI.
    public nonisolated func streamComplete(prompt: String, system: String?, model: String,
                                           timeout: TimeInterval) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let providers = await self.orderedProviders()
                var lastError: Error = LLMError.allProvidersFailed("no providers")
                for (i, provider) in providers.enumerated() {
                    do { try Task.checkCancellation() }
                    catch { continuation.finish(throwing: error); return }
                    var sawDelta = false
                    do {
                        for try await ev in provider.streamComplete(prompt: prompt, system: system,
                                                                    model: model, timeout: timeout) {
                            if case .delta = ev { sawDelta = true }   // .ready alone still allows fallback
                            if case .done = ev { await self.recordUse(provider.id, fellBack: i > 0) }
                            continuation.yield(ev)
                        }
                        continuation.finish(); return
                    } catch let e as LLMError where !sawDelta && Self.isAvailabilityFailure(e) {
                        lastError = e
                        continue   // nothing shown yet — safe to try the other subscription
                    } catch {
                        continuation.finish(throwing: error); return   // mid-stream → honest failure
                    }
                }
                continuation.finish(throwing: LLMError.allProvidersFailed("\(lastError)"))
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func orderedProviders() -> [any LLMProvider] { ordered }
    private func recordUse(_ id: ProviderID, fellBack: Bool) { lastUsed = id; lastFellBack = fellBack }

    /// Try the primary; on an AVAILABILITY failure, fall back to the secondary. Track who answered.
    private func route<T: Sendable>(_ op: @Sendable (any LLMProvider) async throws -> T) async throws -> T {
        let providers = ordered
        var lastError: Error = LLMError.allProvidersFailed("no providers")
        for (i, provider) in providers.enumerated() {
            // Stop pressed → the primary's SIGTERM surfaces as a plain nonZeroExit (the runners don't throw
            // CancellationError); WITHOUT this check the broadened fallback would spawn a SECOND CLI child on
            // a turn the user explicitly cancelled, burning the other subscription (audit HIGH 2026-07-01).
            try Task.checkCancellation()
            do {
                let result = try await op(provider)
                lastUsed = provider.id
                lastFellBack = i > 0
                return result
            } catch let e as LLMError where Self.isAvailabilityFailure(e) {
                lastError = e
                continue   // try the next provider
            }
            // A non-availability error (a real bad-request the other CLI would fail identically) is the
            // provider's verdict — don't waste a second subscription call.
        }
        throw LLMError.allProvidersFailed("\(lastError)")
    }

    /// Whether a primary-provider failure should fall back to the OTHER subscription. Broadened (2026-07-01)
    /// so a transient Codex/CLI hiccup (nonZeroExit, an empty/undecodable response, a launch/timeout/rate
    /// blip) falls back to Claude instead of dead-ending as "Couldn't reach the AI engine" — the founder hit
    /// exactly that. The ONE exclusion is `.providerError`: the CLI ran and reported a real error envelope
    /// (a bad-request verdict), so the other subscription would fail identically — falling back just burns a
    /// second call. (Cancellation is handled by the checkCancellation above, not here.)
    static func isAvailabilityFailure(_ e: LLMError) -> Bool {
        if case .providerError = e { return false }
        return true
    }
}

/// Thread-safe holder for the primary provider id (read on the actor's executor, written from any thread).
private final class PrimaryBox: @unchecked Sendable {
    private let lock = NSLock(); private var v: ProviderID = .claude
    func set(_ p: ProviderID) { lock.lock(); v = p; lock.unlock() }
    var value: ProviderID { lock.lock(); defer { lock.unlock() }; return v }
}
