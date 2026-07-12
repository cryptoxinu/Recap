import Testing
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
}
