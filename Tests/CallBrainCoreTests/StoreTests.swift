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

    @Test("save then keyword-search round-trips; BM25 finds the right chunk; misses refuse")
    func saveAndSearch() throws {
        let store = try tempStore()
        let m = Meeting(id: "m1", title: "Travis sync — Render", date: "2026-05-14",
                        source: .fireflies, company: "Render")
        try store.saveMeeting(m, chunks: [
            chunk("c0", "m1", 0, "Travis", "On Render, the GPU spot pricing dropped this week.", 12),
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
        try store.saveMeeting(m, chunks: [chunk("c0", "m1", 0, "Travis", "miners and ASICs", 0)])
        try store.saveMeeting(m, chunks: [chunk("c0", "m1", 0, "Travis", "validators and OpenRouter", 0)])
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
        #expect(Store.sanitizeFTS("a AND b") == "\"a\" \"and\" \"b\"")
        #expect(Store.sanitizeFTS("   ").isEmpty)
    }
}
