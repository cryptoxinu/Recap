import Foundation
import Observation
import OSLog
import CallBrainCore

/// Live-assistant latency telemetry (spec P4: "so latency is measurable"). First-token + total per lane,
/// emitted to the unified log — `log stream --predicate 'subsystem == "com.callbrain.liveassistant"'` or
/// Console.app. Cheap, off the hot path, no public API churn.
private let liveLog = Logger(subsystem: "com.callbrain.liveassistant", category: "latency")

/// Records the first-token latency from inside the `@Sendable` token closure (which runs concurrently, so
/// a plain captured `var` isn't allowed). Lock-guarded; only ever written once.
private final class FirstTokenClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Duration?
    func recordIfFirst(_ d: @autoclosure () -> Duration) {
        lock.withLock { if value == nil { value = d() } }
    }
    var elapsed: Duration? { lock.withLock { value } }
}

/// Main-actor mini-chat over the currently recording call's rolling transcript.
///
/// Dual-answer (spec P2): each question is answered by TWO lanes at once — an INSTANT local lane
/// (`askLiveFast`, Ollama, sub-second) and a SMART lane (`askLive`, CLI/sonnet, streams in over a few
/// seconds). Both answer the SAME question over the SAME live transcript; they write DISJOINT fields of
/// the same message, always on the main actor, so there's no data race. The UI (P3) shows Fast first in
/// a `Fast ⚡ | Smart ✨` tab and lets the user switch to Smart when it lands.
///
/// Lifecycle (founder: nothing resident when idle) — `warmUp()` primes the local model at record-start;
/// `stop()` cancels in-flight work AND hard-unloads the local model.
@MainActor
@Observable
public final class LiveAssistantModel {
    public struct Message: Identifiable, Equatable, Sendable {
        public let id: Int
        public enum Role: Sendable, Equatable { case user, assistant }
        public enum Lane: Sendable, Equatable { case fast, smart }
        /// A lane's progress. `.unavailable` means that lane won't produce an answer (not configured, or
        /// the provider was down) — the UI hides its tab.
        public enum Phase: Sendable, Equatable { case idle, streaming, done, unavailable }

        public let role: Role
        public var fastText: String
        public var smartText: String
        public var fastPhase: Phase
        public var smartPhase: Phase
        /// Which lane the UI is currently showing. Defaults to `.fast` (instant), flips to `.smart` only
        /// if Fast is unavailable — the user drives switching once both exist.
        public var activeTab: Lane

        init(id: Int, role: Role, fastText: String = "", smartText: String = "",
             fastPhase: Phase = .idle, smartPhase: Phase = .idle, activeTab: Lane = .fast) {
            self.id = id; self.role = role
            self.fastText = fastText; self.smartText = smartText
            self.fastPhase = fastPhase; self.smartPhase = smartPhase
            self.activeTab = activeTab
        }

        /// Text of the currently-shown lane — what the (pre-tab) UI renders. User rows keep their text
        /// in `fastText`.
        public var text: String {
            switch activeTab {
            case .fast: return fastText
            case .smart: return smartText
            }
        }

        /// Is the currently-shown lane still streaming? (Drives the caret / typing indicator.)
        public var streaming: Bool {
            switch activeTab {
            case .fast: return fastPhase == .streaming
            case .smart: return smartPhase == .streaming
            }
        }

        /// The authoritative text for conversation history: prefer the smart answer once it's done,
        /// else the fast answer. (History continuity should follow the best answer, not the shown tab.)
        public var authoritativeText: String {
            if smartPhase == .done, !smartText.isEmpty { return smartText }
            if fastPhase == .done, !fastText.isEmpty { return fastText }
            return smartText.isEmpty ? fastText : smartText
        }

        public var isFastVisibleTab: Bool { activeTab == .fast }
    }

    public private(set) var messages: [Message] = []
    public private(set) var isAnswering = false
    /// Pre-fetched "what should I ask next" chips.
    public private(set) var suggestions: [String] = []

    private let ask: any LiveAsk
    private let transcript: @MainActor () -> String
    private let recentCharLimit: Int
    /// Fast lane reads a TIGHTER window than smart — a recap needs the last exchange, not the whole call,
    /// and a smaller prompt is a lower first-token latency (spec P4 tuning; safe default here).
    private let fastCharLimit: Int
    private let suggestEverySeconds: Double
    private var nextID = 0
    private var answerTask: Task<Void, Never>?
    private var suggestionTask: Task<Void, Never>?
    /// The one-off suggestion refresh (distinct from the periodic loop). Tracked so `stop()` can await it
    /// before unloading — suggestions now use the local lane, so a stray refresh could re-pin Ollama.
    private var refreshTask: Task<Void, Never>?
    private var warmUpTask: Task<Void, Never>?

    public init(ask: LiveAsk, transcript: @escaping @MainActor () -> String,
                recentCharLimit: Int = 6000, fastCharLimit: Int = 2200, suggestEverySeconds: Double = 30) {
        self.ask = ask
        self.transcript = transcript
        self.recentCharLimit = max(0, recentCharLimit)
        self.fastCharLimit = max(0, fastCharLimit)
        self.suggestEverySeconds = suggestEverySeconds
    }

    /// Fire-and-forget send used by UI controls.
    public func send(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !isAnswering else { return }
        isAnswering = true
        answerTask = Task { [weak self] in await self?.sendAndWait(q) }
    }

    /// Fire-and-forget suggestion refresh used by UI lifecycle hooks. Tracked + single-flight so a stray
    /// refresh (which now uses the local lane) can't outlive `stop()` and re-pin the model.
    public func refreshSuggestions() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in await self?.refreshSuggestionsAndWait() }
    }

    /// Warm the local fast model at record-start so the first in-call answer is instant. Best-effort.
    /// Tracked so `stop()` can cancel it and unload AFTER it settles — otherwise a prewarm finishing after
    /// the unload would re-pin the model (audit HIGH: nothing may linger past record-stop).
    public func warmUp() {
        guard ask.hasFastLane else { return }
        warmUpTask = Task { [ask] in await ask.prewarmFast() }
    }

    /// Begin periodic proactive suggestion pre-fetches. Only resets the suggestion loop — must NOT
    /// cancel an in-flight answer (audit: the full stop() here killed the user's streaming reply).
    public func startAutoSuggestions() {
        suggestionTask?.cancel()
        refreshSuggestions()
        let interval = suggestEverySeconds
        suggestionTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                await self?.refreshSuggestionsAndWait()
            }
        }
    }

    /// Stop periodic suggestion pre-fetches AND in-flight answers, and hard-release the local fast model
    /// (founder: nothing resident when the call is over). We cancel every task that could touch Ollama and
    /// AWAIT their unwind BEFORE unloading — a request with `keep_alive` finishing after the unload would
    /// otherwise re-pin the model past record-stop (audit HIGH).
    public func stop() {
        let answer = answerTask, suggestion = suggestionTask, refresh = refreshTask, warm = warmUpTask
        answerTask = nil; suggestionTask = nil; refreshTask = nil; warmUpTask = nil
        answer?.cancel(); suggestion?.cancel(); refresh?.cancel(); warm?.cancel()
        Task { [ask] in
            // Await EVERY task that could hit Ollama (incl. the one-off refresh) before unloading, so
            // none can re-pin the model after release (audit HIGH).
            _ = await answer?.value
            _ = await suggestion?.value
            _ = await refresh?.value
            _ = await warm?.value
            await ask.releaseFast()
        }
    }

    /// Reset the chat transcript while keeping suggestion state intact.
    public func clear() {
        messages = []
    }

    /// The user drives which lane is shown; default is Fast (instant). No-op for non-assistant rows.
    public func showLane(_ lane: Message.Lane, for id: Int) {
        messages = messages.map { m in
            guard m.id == id, m.role == .assistant else { return m }
            var copy = m; copy.activeTab = lane; return copy
        }
    }

    /// Run one full send deterministically for tests — launches BOTH lanes concurrently and returns
    /// only when both have settled.
    func sendAndWait(_ query: String) async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        if !isAnswering { isAnswering = true }
        defer {
            isAnswering = false
            answerTask = nil
        }
        await runSendTurn(q)
    }

    private func runSendTurn(_ q: String) async {
        guard !Task.isCancelled else { return }
        let priorMessages = messages
        let hasFast = ask.hasFastLane
        let userMessage = Message(id: nextMessageID(), role: .user, fastText: q,
                                  fastPhase: .done, smartPhase: .done)
        let assistantID = nextMessageID()
        // Fast starts streaming if available, else it's immediately unavailable and we show Smart.
        let assistant = Message(id: assistantID, role: .assistant,
                                fastPhase: hasFast ? .streaming : .unavailable,
                                smartPhase: .streaming,
                                activeTab: hasFast ? .fast : .smart)
        messages = messages + [userMessage, assistant]

        let history = Self.history(from: priorMessages)

        // Both lanes run concurrently; each writes only its own fields (main-actor coalesced → no race).
        async let fastDone: Void = runFastLane(q, history: history, id: assistantID, enabled: hasFast)
        async let smartDone: Void = runSmartLane(q, history: history, id: assistantID)
        _ = await fastDone
        _ = await smartDone
    }

    private func runFastLane(_ q: String, history: [AskEngine.Turn], id: Int, enabled: Bool) async {
        guard enabled else { return }   // phase already set to .unavailable
        let clock = ContinuousClock(); let start = clock.now; let firstToken = FirstTokenClock()
        do {
            let final = try await ask.askLiveFast(
                q, transcript: recentText(limit: fastCharLimit), history: history,
                onToken: { [weak self] delta in
                    firstToken.recordIfFirst(clock.now - start)
                    await self?.appendDelta(delta, lane: .fast, to: id)
                })
            guard !Task.isCancelled else { return }
            finishLane(id, lane: .fast, text: final)
            liveLog.info("fast lane: firstToken=\(Self.ms(firstToken.elapsed))ms total=\(Self.ms(clock.now - start))ms")
        } catch {
            guard !Task.isCancelled else { return }
            // Ollama down / not configured → hide the Fast tab; Smart carries the answer.
            markUnavailable(id, lane: .fast)
            liveLog.info("fast lane unavailable after \(Self.ms(clock.now - start))ms: \(error.localizedDescription)")
        }
    }

    private func runSmartLane(_ q: String, history: [AskEngine.Turn], id: Int) async {
        let clock = ContinuousClock(); let start = clock.now; let firstToken = FirstTokenClock()
        do {
            let final = try await ask.askLive(
                q, transcript: recentText(limit: recentCharLimit), history: history,
                onToken: { [weak self] delta in
                    firstToken.recordIfFirst(clock.now - start)
                    await self?.appendDelta(delta, lane: .smart, to: id)
                })
            guard !Task.isCancelled else { return }
            finishLane(id, lane: .smart, text: final)
            liveLog.info("smart lane: firstToken=\(Self.ms(firstToken.elapsed))ms total=\(Self.ms(clock.now - start))ms")
        } catch {
            guard !Task.isCancelled else { return }
            markUnavailable(id, lane: .smart)
            liveLog.info("smart lane failed after \(Self.ms(clock.now - start))ms: \(error.localizedDescription)")
        }
    }

    private static func ms(_ d: Duration?) -> Int {
        guard let d else { return -1 }
        return Int(d / .milliseconds(1))
    }

    /// Refresh proactive question suggestions deterministically for tests.
    func refreshSuggestionsAndWait() async {
        suggestions = await ask.suggestQuestions(from: recentText(limit: recentCharLimit))
    }

    private func recentText(limit: Int) -> String {
        String(transcript().suffix(limit))
    }

    private func nextMessageID() -> Int {
        let id = nextID
        nextID += 1
        return id
    }

    private static func history(from messages: [Message]) -> [AskEngine.Turn] {
        messages.compactMap { message in
            let text = (message.role == .user ? message.fastText : message.authoritativeText)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let role: AskEngine.Turn.Role = message.role == .user ? .user : .assistant
            return AskEngine.Turn(role: role, text: text)
        }
    }

    @MainActor
    private func appendDelta(_ delta: String, lane: Message.Lane, to id: Int) {
        messages = messages.map { message in
            guard message.id == id else { return message }
            var copy = message
            switch lane {
            case .fast: copy.fastText += delta
            case .smart: copy.smartText += delta
            }
            return copy
        }
    }

    private func finishLane(_ id: Int, lane: Message.Lane, text: String) {
        // An EMPTY answer is not a real answer — treat it as unavailable so the UI hides that tab and
        // falls through to the other lane (or the honest fallback if both are empty). Prevents an empty
        // assistant bubble / dead tab (audit HIGH+MED).
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { markUnavailable(id, lane: lane); return }
        messages = messages.map { message in
            guard message.id == id else { return message }
            var copy = message
            switch lane {
            case .fast: copy.fastText = trimmed; copy.fastPhase = .done
            case .smart: copy.smartText = trimmed; copy.smartPhase = .done
            }
            return copy
        }
    }

    private func markUnavailable(_ id: Int, lane: Message.Lane) {
        messages = messages.map { message in
            guard message.id == id else { return message }
            var copy = message
            switch lane {
            case .fast: copy.fastPhase = .unavailable
            case .smart: copy.smartPhase = .unavailable
            }
            // Decide what the UI shows — ORDER-INDEPENDENT (either lane may fail first). If BOTH lanes
            // are gone, surface ONE honest fallback so the bubble is never empty (audit HIGH). Otherwise
            // fall through to whichever lane survives.
            if copy.fastPhase == .unavailable, copy.smartPhase == .unavailable {
                copy.fastText = "I couldn't answer from the live transcript yet. Try again in a moment."
                copy.smartText = ""
                copy.fastPhase = .done
                copy.activeTab = .fast
            } else if copy.fastPhase == .unavailable {
                copy.activeTab = .smart
            } else if copy.smartPhase == .unavailable, copy.activeTab == .smart {
                copy.activeTab = .fast
            }
            return copy
        }
    }
}
