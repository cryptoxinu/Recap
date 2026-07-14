import Foundation
import Testing
@testable import CallBrainAppCore

/// Caption FRESHNESS — so the live notes/assistant fall back to the on-device audio when the Meet caption
/// stream stops mid-call (CC turned off / extension disconnected) instead of freezing on stale captions
/// (Codex P1). `secondsSinceLastTurn` is the seam the recording model gates the source choice on.
@Suite("MeetSession caption freshness")
struct MeetSessionFreshnessTests {
    @Test("no turns yet → nil (treated as not fresh → audio fallback)")
    func testNilWhenNoTurns() {
        let session = MeetSession()
        #expect(session.secondsSinceLastTurn() == nil)
    }

    @Test("reports seconds since the last relayed turn")
    func testReportsAgeOfLastTurn() {
        let session = MeetSession()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        session.append(speaker: "Alex Rivera", text: "hello", at: t0)
        #expect(session.secondsSinceLastTurn(now: t0.addingTimeInterval(10)) == 10)
        // A fresh turn resets the clock.
        session.append(speaker: "Sam Chen", text: "hi", at: t0.addingTimeInterval(30))
        #expect(session.secondsSinceLastTurn(now: t0.addingTimeInterval(31)) == 1)
    }

    @Test("a stale gap exceeds the recording model's staleness window")
    func testStaleGapDetected() {
        let session = MeetSession()
        let t0 = Date(timeIntervalSince1970: 2_000_000)
        session.append(speaker: "Alex Rivera", text: "last thing said", at: t0)
        // 40s later with no new caption — beyond the 25s window → the model must fall back to audio.
        let age = session.secondsSinceLastTurn(now: t0.addingTimeInterval(40))
        #expect(age == 40)
        #expect((age ?? .infinity) > 25)
    }

    @Test("begin/end/reset clear the freshness clock")
    func testLeaseBoundariesClearFreshness() {
        let session = MeetSession()
        let t0 = Date(timeIntervalSince1970: 3_000_000)
        session.append(speaker: "Alex Rivera", text: "x", at: t0)
        #expect(session.secondsSinceLastTurn(now: t0) != nil)
        session.beginRecording()
        #expect(session.secondsSinceLastTurn() == nil)
        session.append(speaker: "Sam Chen", text: "y", at: t0)
        session.endRecording()
        #expect(session.secondsSinceLastTurn() == nil)
    }
}
