import Testing
import CallBrainCore
@testable import CallBrainAppCore

@Suite("LiveAssistantModel")
struct LiveAssistantModelTests {
    @MainActor
    @Test("sendAndWait appends the user turn and BOTH lanes populate the assistant turn")
    func testSendAndWaitAppendsMessages() async {
        let ask = StubAsk(fast: "Fast recap.", smart: "Smart answer.", deltas: ["Str ", "eam"])
        let model = LiveAssistantModel(ask: ask, transcript: { "Them: They changed pricing." })

        await model.sendAndWait("hi")

        #expect(model.messages.count == 2)
        #expect(model.messages[0].role == .user)
        #expect(model.messages[0].text == "hi")
        let a = model.messages[1]
        #expect(a.role == .assistant)
        #expect(a.fastText == "Fast recap.")
        #expect(a.smartText == "Smart answer.")
        #expect(a.fastPhase == .done)
        #expect(a.smartPhase == .done)
        #expect(a.activeTab == .fast)          // Fast is shown by default (instant)
        #expect(a.text == "Fast recap.")
        #expect(model.isAnswering == false)
    }

    @MainActor
    @Test("both lanes run concurrently: one send = one fast call + one smart call")
    func testBothLanesCalledOnce() async {
        let ask = StubAsk(fast: "F", smart: "S")
        let model = LiveAssistantModel(ask: ask, transcript: { "Them: line." })

        await model.sendAndWait("q?")

        let calls = await ask.recordedCalls()
        #expect(calls.filter { $0.lane == .fast }.count == 1)
        #expect(calls.filter { $0.lane == .smart }.count == 1)
    }

    @MainActor
    @Test("history threads the SMART (authoritative) answer into the next turn")
    func testHistoryThreadsSmartAnswer() async {
        let ask = StubAsk(fast: "fast1", smart: "smart1")
        let model = LiveAssistantModel(ask: ask, transcript: { "Them: Latest line." })

        await model.sendAndWait("first?")
        await model.sendAndWait("second?")

        let calls = await ask.recordedCalls()
        // The second turn's fast+smart calls both see the same history: user "first?" + assistant "smart1".
        let secondTurn = calls.filter { $0.query == "second?" }
        #expect(secondTurn.count == 2)
        for c in secondTurn {
            #expect(c.history.count == 2)
            #expect(c.history.first?.role == .user)
            #expect(c.history.first?.text == "first?")
            #expect(c.history.first?.retrievalHint == nil)
            #expect(c.history.last?.role == .assistant)
            #expect(c.history.last?.text == "smart1")
            #expect(c.history.last?.retrievalHint == nil)
        }
    }

    @MainActor
    @Test("a lane that returns EMPTY text is treated as unavailable, not a done-empty dead tab (audit HIGH)")
    func testEmptyAnswerBecomesUnavailable() async {
        // Fast returns "" (empty answer); Smart returns real text → Fast tab hidden, view shows Smart.
        let ask = StubAsk(fast: "   ", smart: "Real answer.")
        let model = LiveAssistantModel(ask: ask, transcript: { "Them: line." })

        await model.sendAndWait("q?")

        let a = model.messages[1]
        #expect(a.fastPhase == .unavailable)     // empty Fast → unavailable, not .done
        #expect(a.activeTab == .smart)
        #expect(a.text == "Real answer.")
    }

    @MainActor
    @Test("Ollama down: Fast lane goes unavailable and the view falls through to Smart")
    func testFastUnavailableFallsThroughToSmart() async {
        let ask = StubAsk(fast: "unused", smart: "Smart carries.", failFast: true)
        let model = LiveAssistantModel(ask: ask, transcript: { "Them: line." })

        await model.sendAndWait("q?")

        let a = model.messages[1]
        #expect(a.fastPhase == .unavailable)
        #expect(a.smartText == "Smart carries.")
        #expect(a.activeTab == .smart)     // no dead Fast tab
        #expect(a.text == "Smart carries.")
    }

    @MainActor
    @Test("both lanes fail (either order): one honest fallback shown, never an empty bubble")
    func testBothLanesFailShowFallback() async {
        let ask = StubAsk(fast: "x", smart: "y", failFast: true, failSmart: true)
        let model = LiveAssistantModel(ask: ask, transcript: { "Them: line." })

        await model.sendAndWait("q?")

        let a = model.messages[1]
        #expect(a.fastPhase == .done)          // fallback lives on the shown Fast field
        #expect(a.activeTab == .fast)
        #expect(!a.text.isEmpty)               // never an empty answer bubble
        #expect(a.text.contains("couldn't answer"))
    }

    @MainActor
    @Test("no fast lane configured: Smart-only, no fast call is even attempted")
    func testNoFastLaneSmartOnly() async {
        let ask = StubAsk(fast: "x", smart: "Smart only.", hasFast: false)
        let model = LiveAssistantModel(ask: ask, transcript: { "Them: line." })

        await model.sendAndWait("q?")

        let calls = await ask.recordedCalls()
        #expect(calls.allSatisfy { $0.lane == .smart })
        let a = model.messages[1]
        #expect(a.fastPhase == .unavailable)
        #expect(a.activeTab == .smart)
        #expect(a.smartText == "Smart only.")
    }

    @MainActor
    @Test("showLane switches the visible tab; user drives it")
    func testShowLaneSwitchesTab() async {
        let ask = StubAsk(fast: "F", smart: "S")
        let model = LiveAssistantModel(ask: ask, transcript: { "Them: line." })
        await model.sendAndWait("q?")

        let id = model.messages[1].id
        model.showLane(.smart, for: id)
        #expect(model.messages[1].activeTab == .smart)
        #expect(model.messages[1].text == "S")
    }

    @MainActor
    @Test("refreshSuggestionsAndWait populates suggestions")
    func testRefreshSuggestionsPopulatesSuggestions() async {
        let ask = StubAsk(fast: "", smart: "", suggestions: ["Ask about margins?", "Confirm owner?"])
        let model = LiveAssistantModel(ask: ask, transcript: { "Them: Margins changed." })

        await model.refreshSuggestionsAndWait()

        #expect(model.suggestions == ["Ask about margins?", "Confirm owner?"])
    }

    @MainActor
    @Test("send reserves answering synchronously and drops overlapping sends")
    func testSendSingleFlightDropsOverlappingSends() async {
        let ask = StubAsk(fast: "F", smart: "S")
        let model = LiveAssistantModel(ask: ask, transcript: { "Them: Latest line." })

        model.send(" first ")
        #expect(model.isAnswering == true)
        model.send("second")

        await waitForIdle(model)

        let calls = await ask.recordedCalls()
        #expect(Set(calls.map(\.query)) == ["first"])   // "second" dropped while answering
        #expect(model.messages.map(\.role) == [.user, .assistant])
        #expect(model.messages[0].text == "first")
    }
}

@MainActor
private func waitForIdle(_ model: LiveAssistantModel) async {
    for _ in 0..<200 {
        if !model.isAnswering { return }
        await Task.yield()
    }
    Issue.record("Timed out waiting for live assistant model to become idle")
}

private actor StubAsk: LiveAsk {
    struct Call: Equatable, Sendable {
        let lane: LiveAssistantModel.Message.Lane
        let query: String
        let transcript: String
        let history: [AskEngine.Turn]
    }

    private let fast: String
    private let smart: String
    private let deltas: [String]
    private let suggestions: [String]
    private let failFast: Bool
    private let failSmart: Bool
    private let hasFast: Bool
    private var calls: [Call] = []

    init(fast: String, smart: String, deltas: [String] = [], suggestions: [String] = [],
         failFast: Bool = false, failSmart: Bool = false, hasFast: Bool = true) {
        self.fast = fast; self.smart = smart; self.deltas = deltas
        self.suggestions = suggestions; self.failFast = failFast; self.failSmart = failSmart
        self.hasFast = hasFast
    }

    func askLive(_ query: String, transcript: String, history: [AskEngine.Turn],
                 onToken: AskEngine.TokenHandler?) async throws -> String {
        if failSmart { throw LLMError.launchFailed("smart down") }
        calls = calls + [Call(lane: .smart, query: query, transcript: transcript, history: history)]
        for delta in deltas { await onToken?(delta) }
        return smart
    }

    nonisolated var hasFastLane: Bool { hasFast }

    func askLiveFast(_ query: String, transcript: String, history: [AskEngine.Turn],
                     onToken: AskEngine.TokenHandler?) async throws -> String {
        if failFast { throw LLMError.launchFailed("Ollama down") }
        calls = calls + [Call(lane: .fast, query: query, transcript: transcript, history: history)]
        for delta in deltas { await onToken?(delta) }
        return fast
    }

    func prewarmFast() async {}
    func releaseFast() async {}

    func suggestQuestions(from transcript: String) async -> [String] { suggestions }

    func recordedCalls() -> [Call] { calls }
}
