import Testing
import Foundation
@testable import CallBrainAppCore

/// T2 remediation — the recording lease + atomic harvest that keep a live recording's captions safe from
/// the extension's own `/import` reset and from concurrent-append races (Codex audit HIGH×2).
@Suite("MeetSession recording lease")
struct MeetSessionLeaseTests {

    @Test("beginRecording clears prior captions and takes the lease")
    func testBeginRecording() {
        let s = MeetSession()
        s.append(speaker: "Stale", text: "from before we hit record")
        #expect(!s.isEmpty)
        s.beginRecording()
        #expect(s.isEmpty)              // fresh window
        #expect(s.isRecordingLeased)
    }

    @Test("resetUnlessRecording is a no-op while a recording holds the lease")
    func testImportResetDoesNotWipeRecording() {
        let s = MeetSession()
        s.beginRecording()
        s.append(speaker: "Maya", text: "mid-call point")
        s.resetUnlessRecording()       // the extension /import path during a recording
        #expect(!s.isEmpty)            // captions survive
        #expect(s.transcript() == "Maya: mid-call point")
    }

    @Test("resetUnlessRecording clears normally when no recording is active")
    func testImportResetClearsWhenIdle() {
        let s = MeetSession()
        s.append(speaker: "Maya", text: "hello")
        s.resetUnlessRecording()
        #expect(s.isEmpty)
    }

    @Test("endRecording snapshots the turns, clears the buffer, and drops the lease")
    func testEndRecording() {
        let s = MeetSession()
        s.beginRecording()
        s.append(speaker: "Alex", text: "one")
        s.append(speaker: "Maya", text: "two")
        let harvest = s.endRecording()
        #expect(harvest.turns.map(\.speaker) == ["Alex", "Maya"])
        #expect(harvest.turns.map(\.text) == ["one", "two"])
        #expect(!harvest.truncated)    // nothing evicted
        #expect(s.isEmpty)             // buffer cleared
        #expect(!s.isRecordingLeased)  // lease dropped
        // …and after the lease is gone, /import reset works again.
        s.append(speaker: "Later", text: "next call")
        s.resetUnlessRecording()
        #expect(s.isEmpty)
    }

    @Test("endRecording on an empty window returns no turns and is safe on any stop path")
    func testEndRecordingEmpty() {
        let s = MeetSession()
        s.beginRecording()
        let harvest = s.endRecording()
        #expect(harvest.turns.isEmpty)
        #expect(!harvest.truncated)
        #expect(!s.isRecordingLeased)
    }

    @Test("endRecording reports truncated when the cap evicts turns during a recording (T2 audit MED)")
    func testEndRecordingTruncated() {
        let s = MeetSession(maxTurns: 3, maxTotalBytes: 512 * 1_024)
        s.beginRecording()
        for i in 0..<10 { s.append(speaker: "S\(i)", text: "turn \(i)") }   // exceeds the 3-turn cap
        let harvest = s.endRecording()
        #expect(harvest.turns.count == 3)      // only the most-recent 3 survive
        #expect(harvest.truncated)             // …and we KNOW the head was dropped
    }

    @Test("truncation flag is scoped to the lease and resets each recording")
    func testTruncatedResetsPerRecording() {
        let s = MeetSession(maxTurns: 3)
        s.beginRecording()
        for i in 0..<10 { s.append(speaker: "S\(i)", text: "t\(i)") }
        #expect(s.endRecording().truncated)
        // A fresh recording that stays under the cap must NOT report truncated.
        s.beginRecording()
        s.append(speaker: "A", text: "short call")
        #expect(!s.endRecording().truncated)
    }

    // ── T4: bind captions to one meeting tab ──

    @Test("second-tab captions are dropped while bound to owner tab A")
    func testSecondTabDroppedWhileBound() {
        let s = MeetSession()
        s.beginRecording(ownerTab: 1)              // extension named tab 1 up front
        s.append(speaker: "Alex", text: "owner tab line", tab: 1)   // kept
        s.append(speaker: "Intruder", text: "other tab line", tab: 2)   // different tab → dropped
        #expect(s.transcript() == "Alex: owner tab line")
        let harvest = s.endRecording()
        #expect(harvest.turns.map(\.speaker) == ["Alex"])
    }

    @Test("app-initiated recording binds captions to the first writer's tab")
    func testAppInitiatedBindsFirstWriter() {
        let s = MeetSession()
        s.beginRecording()                          // ownerTab nil → bind first-writer-wins
        s.append(speaker: "Maya", text: "first writer", tab: 7)    // binds tab 7
        s.append(speaker: "Other", text: "from tab nine", tab: 9)  // different tab → dropped
        s.append(speaker: "Maya", text: "still tab seven", tab: 7) // same bound tab → kept
        #expect(s.transcript() == "Maya: first writer\nMaya: still tab seven")
    }

    @Test("legacy nil-tab captions are always accepted (back-compat)")
    func testLegacyNilTabAlwaysAccepted() {
        // Even bound to a specific owner tab, a caption with NO tab id (legacy extension) is kept.
        let s = MeetSession()
        s.beginRecording(ownerTab: 1)
        s.append(speaker: "Alex", text: "tab one", tab: 1)
        s.append(speaker: "Legacy", text: "no tab id")   // tab nil → accepted despite the binding
        #expect(s.transcript() == "Alex: tab one\nLegacy: no tab id")

        // And an entirely tab-less recording (legacy extension end-to-end) accepts every caption.
        let s2 = MeetSession()
        s2.beginRecording()
        s2.append(speaker: "A", text: "one")
        s2.append(speaker: "B", text: "two")
        #expect(s2.transcript() == "A: one\nB: two")
    }

    @Test("a dropped foreign-tab caption leaves the freshness clock untouched")
    func testDroppedForeignTabDoesNotRefreshFreshness() {
        let s = MeetSession()
        let t0 = Date(timeIntervalSince1970: 1_000)
        s.beginRecording(ownerTab: 1)
        s.append(speaker: "Alex", text: "owner", tab: 1, at: t0)
        // A later foreign-tab caption is dropped and must NOT move the freshness clock forward.
        s.append(speaker: "Intruder", text: "other", tab: 2, at: t0.addingTimeInterval(30))
        #expect(s.secondsSinceLastTurn(now: t0.addingTimeInterval(30)) == 30)   // measured from t0, not t0+30
    }

    @Test("the tab binding does not leak into the next recording")
    func testBindingResetsPerRecording() {
        let s = MeetSession()
        s.beginRecording(ownerTab: 1)
        s.append(speaker: "Alex", text: "call one", tab: 1)
        _ = s.endRecording()
        // A brand-new app-initiated recording must accept a DIFFERENT tab as its first writer.
        s.beginRecording()
        s.append(speaker: "Maya", text: "call two", tab: 2)
        #expect(s.transcript() == "Maya: call two")
    }
}
