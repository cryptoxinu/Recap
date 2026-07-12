import Testing
import Foundation
@testable import CallBrainCore

/// Phase 0 (perfection plan): the retrieval eval harness that every later phase's
/// non-regression gate runs through. A "hit" = any top-k result whose meeting title
/// or chunk text matches the gold expectation.
@Suite("RetrievalEval (gold-set hit@k)")
struct RetrievalEvalTests {

    private func freshStore() throws -> Store {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("cb-eval-\(UUID().uuidString).sqlite").path
        return try Store(path: path)
    }

    /// Two meetings with distinct vocab so title- and text-anchored expectations are separable.
    private func seed(_ store: Store, embedder: StubEmbedder, space: String) async throws {
        let a = Meeting(id: "mA", title: "Render pricing sync", date: "2026-06-20", source: .fireflies)
        let b = Meeting(id: "mB", title: "Validator onboarding", date: "2026-06-21", source: .fireflies)
        let rows: [(Meeting, String, String, String)] = [
            (a, "cA1", "Riley", "The GPU spot pricing on Render dropped again this week."),
            (b, "cB1", "Dom", "Validators stake to secure the network and earn logits rewards."),
        ]
        for (m, cid, speaker, text) in rows {
            try store.saveMeeting(m, chunks: [Store.ChunkInput(
                chunkID: cid, meetingID: m.id, version: 0, seq: 0, speaker: speaker,
                tStart: 0, tEnd: 1, text: text, contentHash: "blake3:\(cid)")])
            let v = try await embedder.embed([text], kind: .document)[0]
            try store.saveEmbedding(chunkID: cid, space: space, dim: embedder.dim,
                                    modelID: embedder.modelID, vector: v, contentHash: "blake3:\(cid)")
        }
    }

    @Test("hit@k counts title and text matches; misses score zero")
    func testHitAtKCountsTitleAndTextMatches() async throws {
        let store = try freshStore()
        let embedder = StubEmbedder()
        let space = "stub__v1"
        try await seed(store, embedder: embedder, space: space)
        let engine = SearchEngine(store: store, embedder: embedder, space: space)

        let gold = [
            // title-anchored: query about GPU pricing should land in meeting A by title.
            GoldQuestion(question: "what happened with GPU pricing on render",
                         expectMeetingTitleContains: "Render pricing", expectTextContains: nil, dateScope: nil),
            // text-anchored: query about validators should surface the staking chunk by text.
            GoldQuestion(question: "how do validators earn rewards",
                         expectMeetingTitleContains: nil, expectTextContains: "stake to secure", dateScope: nil),
        ]
        let good = try await RetrievalEval.run(search: engine, gold: gold, k: 5)
        #expect(good.hitAtK == 1.0)
        #expect(good.perQuestion.count == 2)
        #expect(good.perQuestion.allSatisfy { $0.hit })

        let miss = [GoldQuestion(question: "quarterly kangaroo budget forecast",
                                 expectMeetingTitleContains: "Nonexistent Call",
                                 expectTextContains: nil, dateScope: nil)]
        let bad = try await RetrievalEval.run(search: engine, gold: miss, k: 5)
        #expect(bad.hitAtK == 0.0)
    }

    @Test("empty gold set yields zero questions, not a crash or NaN")
    func testEmptyGoldSet() async throws {
        let store = try freshStore()
        let embedder = StubEmbedder()
        let engine = SearchEngine(store: store, embedder: embedder, space: "stub__v1")
        let r = try await RetrievalEval.run(search: engine, gold: [], k: 5)
        #expect(r.perQuestion.isEmpty)
        #expect(r.hitAtK == 0.0)
    }

    @Test("gold set JSON decodes from the checked-in schema")
    func testGoldQuestionDecodes() throws {
        let json = #"[{"question":"q","expectMeetingTitleContains":"t","expectTextContains":null,"dateScope":null}]"#
        let gold = try JSONDecoder().decode([GoldQuestion].self, from: Data(json.utf8))
        #expect(gold.count == 1)
        #expect(gold[0].expectMeetingTitleContains == "t")
    }

    @Test("dateScope gates candidates exactly like the production date filter")
    func testDateScopeGatesCandidates() async throws {
        let store = try freshStore()
        let embedder = StubEmbedder()
        let space = "stub__v1"
        try await seed(store, embedder: embedder, space: space)   // mA=2026-06-20, mB=2026-06-21
        let engine = SearchEngine(store: store, embedder: embedder, space: space)

        // In-window: the validator chunk (mB, 06-21) is reachable.
        let inWindow = [GoldQuestion(question: "how do validators earn rewards",
                                     expectMeetingTitleContains: nil,
                                     expectTextContains: "stake to secure",
                                     dateScope: "2026-06-21..2026-06-22")]
        #expect(try await RetrievalEval.run(search: engine, gold: inWindow, k: 5).hitAtK == 1.0)

        // Out-of-window: same question scoped to a window that excludes mB must MISS.
        let outWindow = [GoldQuestion(question: "how do validators earn rewards",
                                      expectMeetingTitleContains: nil,
                                      expectTextContains: "stake to secure",
                                      dateScope: "2026-06-20..2026-06-21")]
        #expect(try await RetrievalEval.run(search: engine, gold: outWindow, k: 5).hitAtK == 0.0)
    }

    @Test("readOnlySnapshot copies a store without touching the source (cbeval safety path)")
    func testReadOnlySnapshot() async throws {
        let srcPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("cb-snapsrc-\(UUID().uuidString).sqlite").path
        let store = try Store(path: srcPath)
        let embedder = StubEmbedder()
        try await seed(store, embedder: embedder, space: "stub__v1")
        let snap = FileManager.default.temporaryDirectory
            .appendingPathComponent("cb-snap-\(UUID().uuidString).sqlite").path
        try Store.readOnlySnapshot(of: srcPath, to: snap)
        let copy = try Store(path: snap)
        #expect(try copy.keywordSearch("validators", limit: 5).count
                == (try store.keywordSearch("validators", limit: 5).count))
    }
}
