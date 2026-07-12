import Testing
import Foundation
@testable import CallBrainCore

@Suite("Store (SQLite + FTS5)")
struct StoreTests {

    private func tempStore() throws -> Store {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("callbrain-test-\(UUID().uuidString).sqlite").path
        return try Store(path: path)
    }

    private func chunk(_ id: String, _ meeting: String, _ seq: Int, _ speaker: String,
                       _ text: String, _ t: Double) -> Store.ChunkInput {
        Store.ChunkInput(chunkID: id, meetingID: meeting, version: 0, seq: seq, speaker: speaker,
                         tStart: t, tEnd: t + 5, text: text, contentHash: "blake3:\(id)")
    }

    @Test("setMeetingTitle renames the display title (via ai_title), keeps the original, empty clears it")
    func renameMeeting() throws {
        let store = try tempStore()
        try store.saveMeeting(Meeting(id: "m1", title: "2026-06-30 09:00 meeting", date: "2026-06-30", source: .fathom),
                              chunks: [chunk("c1", "m1", 0, "Alex", "hi", 0)])
        #expect(try store.meeting(id: "m1")?.displayTitle == "2026-06-30 09:00 meeting")   // falls back to raw
        try store.setMeetingTitle(id: "m1", title: "  Wearable Tech Chat  ")
        let renamed = try store.meeting(id: "m1")
        #expect(renamed?.displayTitle == "Wearable Tech Chat")     // trimmed override shows
        #expect(renamed?.title == "2026-06-30 09:00 meeting")      // original preserved
        try store.setMeetingTitle(id: "m1", title: "   ")           // empty clears the override
        #expect(try store.meeting(id: "m1")?.displayTitle == "2026-06-30 09:00 meeting")
    }

    @Test("save then keyword-search round-trips; BM25 finds the right chunk; misses refuse")
    func saveAndSearch() throws {
        let store = try tempStore()
        let m = Meeting(id: "m1", title: "Riley sync — Render", date: "2026-05-14",
                        source: .fireflies, company: "Render")
        try store.saveMeeting(m, chunks: [
            chunk("c0", "m1", 0, "Riley", "On Render, the GPU spot pricing dropped this week.", 12),
            chunk("c1", "m1", 1, "Me", "Does that change the validator economics?", 18),
        ])
        #expect(try store.meetingCount() == 1)
        #expect(try store.chunkCount() == 2)

        #expect(try store.keywordSearch("Render").map(\.chunkID) == ["c0"])
        #expect(try store.keywordSearch("validator").first?.chunkID == "c1")
        #expect(try store.keywordSearch("Solana").isEmpty)        // honest miss
    }

    @Test("re-saving the same chunk id updates FTS (no duplicate, no stale row)")
    func upsertKeepsFTSConsistent() throws {
        let store = try tempStore()
        let m = Meeting(id: "m1", title: "t", date: "2026-05-14", source: .fathom)
        try store.saveMeeting(m, chunks: [chunk("c0", "m1", 0, "Riley", "miners and ASICs", 0)])
        try store.saveMeeting(m, chunks: [chunk("c0", "m1", 0, "Riley", "validators and OpenRouter", 0)])
        #expect(try store.chunkCount() == 1)
        #expect(try store.keywordSearch("ASICs").isEmpty)                  // old text gone from FTS
        #expect(try store.keywordSearch("OpenRouter").first?.chunkID == "c0")
    }

    @Test("end-to-end: Fireflies → chunk → store → search")
    func endToEnd() throws {
        let store = try tempStore()
        let parsed = try FirefliesParser.parse(Data(FirefliesParserTests.sample.utf8))
        let meetingID = "m_e2e"
        let utterances = parsed.utterances.map { pu in
            Utterance(id: "u_\(pu.seq)", meetingID: meetingID, version: 0, seq: pu.seq,
                      speakerRaw: pu.speakerRaw, speakerConfidence: pu.speakerConfidence,
                      tStart: pu.tStart, tEnd: pu.tEnd, text: pu.text,
                      isInferredSpeaker: pu.isInferredSpeaker, tsConfidence: pu.tsConfidence)
        }
        let inputs = Chunker().chunk(utterances).map { ch in
            Store.ChunkInput(chunkID: "\(meetingID)_\(ch.seq)", meetingID: meetingID, version: 0,
                             seq: ch.seq, speaker: ch.speaker, tStart: ch.tStart, tEnd: ch.tEnd,
                             text: ch.text, tokenCount: ch.approxTokens, contentHash: "blake3:\(ch.seq)")
        }
        let m = Meeting(id: meetingID, title: parsed.title ?? "Untitled",
                        date: parsed.date ?? "2026-05-14", source: parsed.source)
        try store.saveMeeting(m, chunks: inputs)

        let hits = try store.keywordSearch("inference hardware")
        #expect(!hits.isEmpty)
        #expect(hits.first?.text.contains("inference hardware") == true)
    }

    @Test("vectors scoping: nil = all, [] = none, [ids] = subset — Codex fix")
    func vectorScoping() throws {
        let store = try tempStore()
        let m = Meeting(id: "m1", title: "t", date: "2026-05-14", source: .fathom)
        try store.saveMeeting(m, chunks: [chunk("c0", "m1", 0, "A", "x", 0), chunk("c1", "m1", 1, "B", "y", 1)])
        try store.saveEmbedding(chunkID: "c0", space: "s", dim: 2, modelID: "m", vector: [1, 0], contentHash: "h0")
        try store.saveEmbedding(chunkID: "c1", space: "s", dim: 2, modelID: "m", vector: [0, 1], contentHash: "h1")
        #expect(try store.vectors(space: "s").count == 2)                       // nil = all
        #expect(try store.vectors(space: "s", chunkIDs: []).isEmpty)            // [] = none
        #expect(try store.vectors(space: "s", chunkIDs: ["c0"]).map(\.id) == ["c0"])
    }

    @Test("FTS sanitizer neutralizes punctuation and operator words")
    func sanitizer() {
        #expect(Store.sanitizeFTS("Render!") == "\"render\"")
        // Operator words stay quoted (can't act as FTS operators); since Task 1.1 tokens are
        // OR-joined — the all-stopword/short fallback keeps every token rather than matching nothing.
        #expect(Store.sanitizeFTS("a AND b") == "\"a\" OR \"and\" OR \"b\"")
        #expect(Store.sanitizeFTS("   ").isEmpty)
    }

    @Test("setSummaryTasks replaces OPEN summary tasks on regenerate but preserves completed ones")
    func summaryTasksReconcile() throws {
        let store = try tempStore()
        let m = Meeting(id: "m1", title: "Sync", date: "2026-06-30", source: .fathom)
        try store.saveMeeting(m, chunks: [chunk("c0", "m1", 0, "Z", "x", 0)])

        try store.setSummaryTasks(meetingID: "m1", items: [
            ActionItemDraft(owner: "Alex", text: "Fix BitRouter format"),
            ActionItemDraft(owner: "Priya", text: "Ship billing page"),
        ])
        #expect(try store.tasks(meetingID: "m1").count == 2)

        // User completes one.
        let done = try #require(try store.tasks(meetingID: "m1").first { $0.text == "Fix BitRouter format" })
        #expect(try store.setTaskStatus(id: done.id, .done) == true)

        // Regenerate: a reworded item + a brand-new one. The completed task survives; the stale OPEN one is
        // replaced, not duplicated.
        try store.setSummaryTasks(meetingID: "m1", items: [
            ActionItemDraft(owner: "Priya", text: "Ship the billing + Stripe page"),
            ActionItemDraft(owner: "Dom", text: "Finalize GPU cost model"),
        ])
        let after = try store.tasks(meetingID: "m1")
        #expect(after.count == 3)                                                  // 1 done + 2 fresh open
        #expect(after.contains { $0.text == "Fix BitRouter format" && $0.status == .done })
        #expect(after.contains { $0.text == "Ship the billing + Stripe page" })
        #expect(after.contains { $0.text == "Finalize GPU cost model" })
        #expect(!after.contains { $0.text == "Ship billing page" })               // stale open one gone
    }

    @Test("setTaskStatus reports whether a row actually changed")
    func taskStatusReportsChange() throws {
        let store = try tempStore()
        let m = Meeting(id: "m1", title: "t", date: "2026-06-30", source: .fathom)
        try store.saveMeeting(m, chunks: [chunk("c0", "m1", 0, "Z", "x", 0)])
        try store.setSummaryTasks(meetingID: "m1", items: [ActionItemDraft(owner: nil, text: "do it")])
        let id = try #require(try store.tasks(meetingID: "m1").first?.id)
        #expect(try store.setTaskStatus(id: id, .done) == true)
        #expect(try store.setTaskStatus(id: "task_nonexistent", .done) == false)
    }
}
