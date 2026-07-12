import Testing
import Foundation
@testable import CallBrainAppCore

/// Perfection plan Task 3.1 — the chat turn lifecycle as a PURE reducer. Every production
/// freeze/Stop bug in this app's history lived in scattered generation-token guards across the
/// untested app layer; here each historical race is a named test over explicit transitions.
@Suite("ChatReducer (turn lifecycle)")
struct ChatReducerTests {

    private func started() -> ChatReducer.State {
        var s = ChatReducer.State()
        var fx = ChatReducer.reduce(&s, .send(question: "what happened with pricing"))
        #expect(fx.contains(.startAsk(generation: s.generation)))
        fx.removeAll()
        return s
    }

    @Test("send starts a turn exactly once; a second send while busy is ignored")
    func testSendOnceWhileBusy() {
        var s = ChatReducer.State()
        let fx1 = ChatReducer.reduce(&s, .send(question: "q1"))
        #expect(fx1.contains(.startAsk(generation: s.generation)))
        let fx2 = ChatReducer.reduce(&s, .send(question: "q2"))
        #expect(fx2.isEmpty)                       // busy — no second CLI
        #expect(s.phase == .awaitingSources)
    }

    @Test("stop during route spawns no second CLI (historical Stop-regression)")
    func testStopDuringRouteSpawnsNoSecondCLI() {
        var s = started()
        let gen = s.generation
        let fxStop = ChatReducer.reduce(&s, .stop)
        #expect(fxStop.contains(.cancelAsk(generation: gen)))
        #expect(s.phase == .idle)
        // Late events from the cancelled generation produce ZERO effects and mutate nothing.
        let stale = ChatReducer.reduce(&s, .sourcesArrived(generation: gen, count: 8))
        #expect(stale.isEmpty)
        #expect(s.sourcesCount == nil)
    }

    @Test("a delta arriving after stop is dropped (historical race)")
    func testDeltaAfterStopIsDropped() {
        var s = started()
        let gen = s.generation
        _ = ChatReducer.reduce(&s, .sourcesArrived(generation: gen, count: 5))
        _ = ChatReducer.reduce(&s, .delta(generation: gen, text: "The pricing "))
        _ = ChatReducer.reduce(&s, .stop)
        let before = s.streamedText
        _ = ChatReducer.reduce(&s, .delta(generation: gen, text: "dropped!"))
        #expect(s.streamedText == before)
    }

    @Test("stop preserves the partial text with a stopped-early marker")
    func testStopPreservesPartialText() {
        var s = started()
        let gen = s.generation
        _ = ChatReducer.reduce(&s, .delta(generation: gen, text: "GPU pricing fell "))
        _ = ChatReducer.reduce(&s, .delta(generation: gen, text: "again this week"))
        _ = ChatReducer.reduce(&s, .stop)
        #expect(s.streamedText == "GPU pricing fell again this week")
        #expect(s.stoppedEarly)
        #expect(s.phase == .idle)
    }

    @Test("a finished answer that failed citation validation REPLACES the streamed text honestly")
    func testRefusalReplacesStreamedText() {
        var s = started()
        let gen = s.generation
        _ = ChatReducer.reduce(&s, .delta(generation: gen, text: "Uncited claims streaming…"))
        _ = ChatReducer.reduce(&s, .finished(generation: gen, finalText: "I couldn't ground an answer to that in your calls.",
                                             cited: false, provider: "claude"))
        #expect(s.streamedText == "I couldn't ground an answer to that in your calls.")
        #expect(s.unverifiedStreamReplaced)        // UI shows the "couldn't verify sources" marker
        #expect(s.phase == .idle)
    }

    @Test("regenerate reuses the last question through a fresh generation")
    func testRegenerateReusesLastQuestion() {
        var s = started()
        let gen = s.generation
        _ = ChatReducer.reduce(&s, .finished(generation: gen, finalText: "Answer.", cited: true, provider: "claude"))
        let fx = ChatReducer.reduce(&s, .regenerate)
        #expect(s.generation == gen + 1)
        #expect(fx.contains(.startAsk(generation: s.generation)))
        #expect(s.lastQuestion == "what happened with pricing")
    }

    @Test("failure surfaces only for the current generation")
    func testStaleFailureIgnored() {
        var s = started()
        let gen = s.generation
        _ = ChatReducer.reduce(&s, .stop)
        _ = ChatReducer.reduce(&s, .send(question: "new question"))
        let fx = ChatReducer.reduce(&s, .failed(generation: gen, message: "old turn died"))
        #expect(fx.isEmpty)
        #expect(s.failureMessage == nil)
        #expect(s.phase == .awaitingSources)       // the NEW turn is untouched
    }
}

/// Round-2 HIGH regression: invalidate must orphan even while IDLE.
@Suite("ChatReducer invalidate")
struct ChatReducerInvalidateTests {
    @Test("invalidate bumps the generation while idle (slow load can't overwrite the new thread)")
    func testInvalidateBumpsWhileIdle() {
        var s = ChatReducer.State()
        let g0 = s.generation
        let fx = ChatReducer.reduce(&s, .invalidate)
        #expect(s.generation == g0 + 1)
        #expect(fx.isEmpty)                       // nothing running → nothing to cancel
        // Mid-flight invalidate cancels the running generation.
        _ = ChatReducer.reduce(&s, .send(question: "q"))
        let g1 = s.generation
        let fx2 = ChatReducer.reduce(&s, .invalidate)
        #expect(fx2 == [.cancelAsk(generation: g1)])
        #expect(s.phase == .idle)
    }
}
