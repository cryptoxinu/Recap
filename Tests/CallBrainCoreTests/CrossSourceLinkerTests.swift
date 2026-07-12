import Testing
import Foundation
@testable import CallBrainCore

/// Perfection plan Task 2.3 — every call was ingested TWICE (Gemini notes + recording), never
/// linked: retrieval double-counts, tasks duplicate, counts inflate (audit CRITICAL). Merge is
/// explicit re-point-then-delete in ONE transaction — the schema's FKs are ON DELETE CASCADE,
/// so deleting first would DESTROY children (judge BLOCKER; there is no re-point machinery).
@Suite("CrossSourceLinker (candidates + conservation merge)")
struct CrossSourceLinkerTests {

    private func freshStore() throws -> Store {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("cb-link-\(UUID().uuidString).sqlite").path
        return try Store(path: path)
    }

    private func save(_ s: Store, id: String, title: String, date: String, source: MeetingSource,
                      chunks: [(String, String)]) throws {
        let m = Meeting(id: id, title: title, date: date, source: source)
        try s.saveMeeting(m, chunks: chunks.enumerated().map { i, c in
            Store.ChunkInput(chunkID: c.0, meetingID: id, version: 0, seq: i, speaker: "S",
                             tStart: Double(i * 30), tEnd: Double(i * 30 + 20), text: c.1,
                             contentHash: "b:\(c.0)")
        })
    }

    // MARK: candidates — the founder's REAL title shapes

    @Test("real corpus shapes pair by title-prefix or time-token, same date only")
    func testCandidatesOnRealShapes() throws {
        let s = try freshStore()
        // Gemini side (clean titles, some with times).
        try save(s, id: "g1", title: "morning sync", date: "2026-06-24", source: .gmeetGemini, chunks: [("gc1", "notes a")])
        try save(s, id: "g2", title: "Meeting started 2026-06-24 10-09 PDT", date: "2026-06-24", source: .gmeetGemini, chunks: [("gc2", "notes b")])
        try save(s, id: "g3", title: "Riley - Alex Quick Sync", date: "2026-06-25", source: .gmeetGemini, chunks: [("gc3", "notes c")])
        // Transcript side (filename-derived titles).
        try save(s, id: "t1", title: "morning sync - 2026-06-24 09-27 PDT - Recording-1T3T", date: "2026-06-24", source: .gmeetLocal, chunks: [("tc1", "verbatim a")])
        try save(s, id: "t2", title: "fsq-iqhe-kam (2026-06-24 10-09 GMT-7)-1ETbeb8fq", date: "2026-06-24", source: .gmeetLocal, chunks: [("tc2", "verbatim b")])
        try save(s, id: "t3", title: "Riley - Alex Quick Sync - 2026-06-25 17-15 EDT - Recording-x", date: "2026-06-25", source: .gmeetLocal, chunks: [("tc3", "verbatim c")])
        // A different-day meeting that must NOT pair.
        try save(s, id: "t4", title: "morning sync - 2026-06-26 09-27 PDT - Recording-zz", date: "2026-06-26", source: .gmeetLocal, chunks: [("tc4", "verbatim d")])

        let pairs = try CrossSourceLinker.candidates(store: s)
        let byGemini = Dictionary(uniqueKeysWithValues: pairs.map { ($0.gemini.id, $0.transcript.id) })
        #expect(byGemini["g1"] == "t1")   // title-prefix match, same date
        #expect(byGemini["g2"] == "t2")   // time-token 10-09 match (titles unrelated)
        #expect(byGemini["g3"] == "t3")   // title-prefix, EDT time only on one side
        #expect(pairs.count == 3)         // t4 (different day) pairs with nothing
    }

    @Test("an ambiguous gemini (two equal transcript matches, same day) is skipped")
    func testAmbiguousSkipped() throws {
        let s = try freshStore()
        try save(s, id: "g1", title: "morning sync", date: "2026-06-24", source: .gmeetGemini, chunks: [("gc1", "n")])
        try save(s, id: "t1", title: "morning sync - 2026-06-24 09-00 PDT - Recording-a", date: "2026-06-24", source: .gmeetLocal, chunks: [("tc1", "v1")])
        try save(s, id: "t2", title: "morning sync - 2026-06-24 15-00 PDT - Recording-b", date: "2026-06-24", source: .gmeetLocal, chunks: [("tc2", "v2")])
        #expect(try CrossSourceLinker.candidates(store: s).isEmpty)
    }

    @Test("conflicting time tokens veto a title match — different same-title calls never merge")
    func testTimeConflictVeto() throws {
        let s = try freshStore()
        // The gemini doc carries 09-00; the only same-day transcript carries 15-00 → different calls.
        try save(s, id: "g1", title: "Meeting started 2026-06-24 09-00 PDT", date: "2026-06-24",
                 source: .gmeetGemini, chunks: [("gc1", "n")])
        try save(s, id: "t1", title: "Meeting started 2026-06-24 15-00 PDT - Recording-b", date: "2026-06-24",
                 source: .gmeetLocal, chunks: [("tc1", "v")])
        #expect(try CrossSourceLinker.candidates(store: s).isEmpty)
    }

    @Test("zero person overlap (both sides known) vetoes a title match")
    func testPersonDisjointVeto() throws {
        let s = try freshStore()
        func saveWith(_ id: String, _ title: String, _ src: MeetingSource, people: [String]) throws {
            let m = Meeting(id: id, title: title, date: "2026-06-24", source: src)
            try s.saveMeeting(m, chunks: [Store.ChunkInput(
                chunkID: "c-\(id)-\(people.count)", meetingID: id, version: 0, seq: 0, speaker: "S",
                tStart: 0, tEnd: 1, text: "hello \(id)", contentHash: "b:\(id)")],
                entities: people.map { Store.EntityInput(name: $0, kind: "person", count: 1) })
        }
        try saveWith("g1", "weekly sync", .gmeetGemini, people: ["Riley"])
        try saveWith("t1", "weekly sync - 2026-06-24 09-00 PDT - Recording", .gmeetLocal, people: ["Priya"])
        #expect(try CrossSourceLinker.candidates(store: s).isEmpty)
        // Shared person → the pair is allowed again.
        try saveWith("t1", "weekly sync - 2026-06-24 09-00 PDT - Recording", .gmeetLocal,
                     people: ["Priya", "Riley"])
        #expect(try CrossSourceLinker.candidates(store: s).count == 1)
    }

    @Test("import-queue rows follow the surviving meeting through a merge")
    func testMergeRepointsImportJobs() throws {
        let s = try freshStore()
        try save(s, id: "g1", title: "sync", date: "2026-06-24", source: .gmeetGemini, chunks: [("gc1", "n")])
        try save(s, id: "t1", title: "sync - 2026-06-24 09-00 PDT - Recording", date: "2026-06-24",
                 source: .gmeetLocal, chunks: [("tc1", "v")])
        try s.upsertImportJob(ImportJob(id: "job1", sourceName: "notes.docx", state: .done,
                                        meetingID: "g1", createdAt: 1))
        _ = try s.mergeMeetings(loserID: "g1", survivorID: "t1")
        #expect(try s.importJobs().first { $0.id == "job1" }?.meetingID == "t1")
    }

    // MARK: merge — conservation is the whole point (judge-named tests)

    @Test("merge conserves chunk and task counts and re-points every child table")
    func testMergeConservesChunkAndTaskCounts() throws {
        let s = try freshStore()
        try save(s, id: "g1", title: "morning sync", date: "2026-06-24", source: .gmeetGemini,
                 chunks: [("gc1", "gemini notes text"), ("gc2", "gemini action items")])
        try save(s, id: "t1", title: "morning sync - 2026-06-24 09-27 PDT - Recording-x", date: "2026-06-24",
                 source: .gmeetLocal, chunks: [("tc1", "verbatim one"), ("tc2", "verbatim two")])
        try s.setSummaryTasks(meetingID: "g1", items: [ActionItemDraft(owner: "Alex", text: "Ship the app")])
        try s.setSummaryTasks(meetingID: "t1", items: [ActionItemDraft(owner: "Dom", text: "Deploy router")])

        let preChunks = try s.chunkCount()
        let stats = try s.mergeMeetings(loserID: "g1", survivorID: "t1")

        #expect(try s.chunkCount() == preChunks)                          // nothing destroyed
        #expect(stats.chunksMoved == 2)
        #expect(try s.meeting(id: "g1") == nil)                          // loser row gone
        #expect(try s.chunkIDs(meetingID: "t1").count == 4)              // all four under survivor
        #expect(try s.tasks(meetingID: "t1").count == 2)                 // both tasks live on survivor
        // The notes text stays retrievable — and cites the SURVIVOR now.
        let hits = try s.keywordSearch("gemini notes", limit: 5)
        #expect(hits.first?.meetingID == "t1")
    }

    @Test("task dedupe-key collisions are dropped, not crashed on (UNIQUE(meeting_id,dedupe_key))")
    func testMergeHandlesTaskDedupeKeyCollision() throws {
        let s = try freshStore()
        try save(s, id: "g1", title: "sync", date: "2026-06-24", source: .gmeetGemini, chunks: [("gc1", "n")])
        try save(s, id: "t1", title: "sync - 2026-06-24 09-00 PDT - Recording", date: "2026-06-24",
                 source: .gmeetLocal, chunks: [("tc1", "v")])
        // The SAME task extracted from both halves → identical dedupe key after re-point.
        try s.setSummaryTasks(meetingID: "g1", items: [ActionItemDraft(owner: "Alex", text: "Ship the app")])
        try s.setSummaryTasks(meetingID: "t1", items: [ActionItemDraft(owner: "Alex", text: "Ship the app")])
        let stats = try s.mergeMeetings(loserID: "g1", survivorID: "t1")
        #expect(stats.tasksDeduped == 1)
        #expect(try s.tasks(meetingID: "t1").count == 1)
    }

    @Test("persisted chat citations are re-pointed to the survivor")
    func testMergeRepointsStoredCitations() throws {
        let s = try freshStore()
        try save(s, id: "g1", title: "sync", date: "2026-06-24", source: .gmeetGemini, chunks: [("gc1", "n")])
        try save(s, id: "t1", title: "sync - 2026-06-24 09-00 PDT - Recording", date: "2026-06-24",
                 source: .gmeetLocal, chunks: [("tc1", "v")])
        let conv = Conversation(id: "conv1", title: "chat", meetingID: nil, createdAt: 1, updatedAt: 1)
        try s.upsertConversation(conv)
        try s.appendMessage(Message(id: "msg1", conversationID: "conv1", role: .assistant,
                                    text: "answer [S1]",
                                    citations: [StoredCitation(tag: "S1", chunkID: "gc1", meetingID: "g1",
                                                               speaker: "S", text: "n", tStart: 0)],
                                    createdAt: 2))
        _ = try s.mergeMeetings(loserID: "g1", survivorID: "t1")
        let msgs = try s.messages(conversationID: "conv1")
        #expect(msgs.last?.citations.first?.meetingID == "t1")
        #expect(msgs.last?.citations.first?.chunkID == "gc1")            // chunk moved, id unchanged
    }

    @Test("merge is idempotent-safe: merging an already-gone loser throws cleanly, changes nothing")
    func testMergeMissingLoserThrows() throws {
        let s = try freshStore()
        try save(s, id: "t1", title: "sync", date: "2026-06-24", source: .gmeetLocal, chunks: [("tc1", "v")])
        #expect(throws: (any Error).self) { try s.mergeMeetings(loserID: "gone", survivorID: "t1") }
        #expect(try s.chunkIDs(meetingID: "t1").count == 1)
    }
}
