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

    /// Try the primary; on an AVAILABILITY failure, fall back to the secondary. Track who answered.
    private func route<T: Sendable>(_ op: @Sendable (any LLMProvider) async throws -> T) async throws -> T {
        let providers = ordered
        var lastError: Error = LLMError.allProvidersFailed("no providers")
        for (i, provider) in providers.enumerated() {
            do {
                let result = try await op(provider)
                lastUsed = provider.id
                lastFellBack = i > 0
                return result
            } catch let e as LLMError where Self.isAvailabilityFailure(e) {
                lastError = e
                continue   // try the next provider
            }
            // A non-availability error (e.g. a real bad-request) is the provider's verdict — don't retry.
        }
        throw LLMError.allProvidersFailed("\(lastError)")
    }

    /// Only these justify falling back to the other subscription — a transient/availability problem.
    static func isAvailabilityFailure(_ e: LLMError) -> Bool {
        switch e {
        case .rateLimited, .notInstalled, .launchFailed, .timedOut: return true
        default: return false
        }
    }
}

/// Thread-safe holder for the primary provider id (read on the actor's executor, written from any thread).
private final class PrimaryBox: @unchecked Sendable {
    private let lock = NSLock(); private var v: ProviderID = .claude
    func set(_ p: ProviderID) { lock.lock(); v = p; lock.unlock() }
    var value: ProviderID { lock.lock(); defer { lock.unlock() }; return v }
}
