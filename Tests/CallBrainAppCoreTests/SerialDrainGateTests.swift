import Testing
@testable import CallBrainAppCore

/// E2 (Task 8.1) — the lost-wakeup race, as named tests instead of an untested coordinator field.
@Suite("SerialDrainGate (E2)")
struct SerialDrainGateTests {

    @Test("first request wins the drain; a second mid-drain request loops instead of stranding")
    func testLostWakeupLoop() {
        var g = SerialDrainGate()
        let first = g.requestDrain(), second = g.requestDrain()
        #expect(first)                        // I run the loop
        #expect(!second)                      // concurrent enqueue → flagged, not a second loop
        let loop1 = g.shouldLoop(), loop2 = g.shouldLoop()
        #expect(loop1)                        // the running loop re-checks → loops again
        #expect(!loop2)                       // flag consumed exactly once
        g.finish()
        #expect(!g.processing)
        let fresh = g.requestDrain()
        #expect(fresh)                        // next enqueue starts a fresh drain
    }

    @Test("a request AFTER finish starts fresh — no stale loop flag")
    func testNoStaleFlag() {
        var g = SerialDrainGate()
        _ = g.requestDrain()
        g.finish()                            // exited without a mid-drain request
        let fresh = g.requestDrain(), pending = g.shouldLoop()
        #expect(fresh)
        #expect(!pending)                     // nothing pending
    }
}
