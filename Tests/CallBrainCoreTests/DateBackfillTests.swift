import Testing
import Foundation
@testable import CallBrainCore

/// Perfection plan Task 2.2 — re-derive real call dates for EXISTING transcribed meetings
/// (all 8 gmeet_local rows in the production store carry the import day, with the true date
/// trapped in the title). STANDALONE function, never a registered migration: the migrator
/// auto-runs on every Store.init, which would bypass the plan/--apply review gate (judge MAJOR).
@Suite("DateBackfill (plan → apply, confident-only, idempotent)")
struct DateBackfillTests {

    private func store(with meetings: [(id: String, title: String, date: String, source: MeetingSource)]) throws -> Store {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("cb-backfill-\(UUID().uuidString).sqlite").path
        let s = try Store(path: path)
        for m in meetings {
            try s.saveMeeting(Meeting(id: m.id, title: m.title, date: m.date, source: m.source),
                              chunks: [Store.ChunkInput(chunkID: "c-\(m.id)", meetingID: m.id, version: 0,
                                                        seq: 0, speaker: "S", tStart: 0, tEnd: 1,
                                                        text: "hello world \(m.id)", contentHash: "b:\(m.id)")])
        }
        return s
    }

    @Test("plan finds only wrong-dated transcribed meetings with a confident filename date")
    func testPlanFindsWrongDates() throws {
        let s = try store(with: [
            ("m1", "morning sync - 2026-06-30 09-29 PDT - Recording-1TtWz", "2026-07-01", .gmeetLocal),
            ("m2", "already right - 2026-06-25 10-00 PDT - Recording-x", "2026-06-25", .gmeetLocal),
            ("m3", "no date in this title", "2026-07-01", .gmeetLocal),
            ("m4", "gemini notes - 2026-06-20 09-00 PDT", "2026-07-01", .gmeetGemini),  // wrong source — untouched
        ])
        let changes = try DateBackfill.plan(store: s)
        #expect(changes.count == 1)
        #expect(changes.first?.meetingID == "m1")
        #expect(changes.first?.oldDate == "2026-07-01")
        #expect(changes.first?.newDate == "2026-06-30")
    }

    @Test("apply writes the new dates; re-plan is then empty (idempotent)")
    func testApplyThenIdempotent() throws {
        let s = try store(with: [
            ("m1", "morning sync - 2026-06-30 09-29 PDT - Recording-1TtWz", "2026-07-01", .gmeetLocal),
        ])
        let changes = try DateBackfill.plan(store: s)
        let applied = try DateBackfill.apply(store: s, changes: changes)
        #expect(applied == 1)
        #expect(try s.meeting(id: "m1")?.date == "2026-06-30")
        #expect(try DateBackfill.plan(store: s).isEmpty)
        // Re-apply of stale changes must be a no-op, not a corruption.
        #expect(try DateBackfill.apply(store: s, changes: changes) == 0)
    }

    @Test("plan without apply mutates nothing")
    func testPlanIsReadOnly() throws {
        let s = try store(with: [
            ("m1", "sync - 2026-06-28 09-00 PDT - Recording-a", "2026-07-01", .gmeetLocal),
        ])
        _ = try DateBackfill.plan(store: s)
        #expect(try s.meeting(id: "m1")?.date == "2026-07-01")
    }
}
