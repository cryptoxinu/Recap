import Testing
import Foundation
@testable import CallBrainCore

/// Deterministic offline embedder: vectorizes by presence of a fixed crypto/infra vocab, so the
/// semantic lane is testable without Ollama. Same model embeds documents + queries (consistent space).
struct StubEmbedder: Embedder {
    let modelID = "stub-vocab"
    let dim = 6
    static let vocab = ["render", "validator", "asic", "gpu", "pricing", "logits"]

    func embed(_ texts: [String], kind: EmbedKind) async throws -> [[Float]] {
        texts.map { text in
            let lower = text.lowercased()
            return Self.vocab.map { lower.contains($0) ? Float(1) : Float(0) }
        }
    }
}

struct FixedQueryEmbedder: Embedder {
    let modelID = "fixed-query"
    let dim = 3
    let queryVector: [Float]

    func embed(_ texts: [String], kind: EmbedKind) async throws -> [[Float]] {
        texts.map { _ in kind == .query ? queryVector : [0, 0, 0] }
    }
}

struct EmptyQueryEmbedder: Embedder {
    let modelID = "empty-query"
    let dim = 3

    func embed(_ texts: [String], kind: EmbedKind) async throws -> [[Float]] {
        texts.map { _ in [] }
    }
}

@Suite("SearchEngine (hybrid FTS + vector + RRF)")
struct SearchEngineTests {

    private func freshStore() throws -> Store {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("cb-search-\(UUID().uuidString).sqlite").path
        return try Store(path: path)
    }

    /// Save chunks with both FTS text (via saveMeeting) and stub document embeddings.
    private func seed(_ store: Store, embedder: StubEmbedder, space: String) async throws {
        let m = Meeting(id: "m1", title: "infra sync", date: "2026-05-14", source: .fireflies)
        let chunks: [(String, String, String)] = [
            ("c_render", "Riley", "On Render, the GPU spot pricing dropped this week."),
            ("c_val",    "Dom",    "Validators stake to secure the network economics."),
            ("c_asic",   "JW",     "The ASIC miners changed our inference hardware math."),
        ]
        try store.saveMeeting(m, chunks: chunks.map {
            Store.ChunkInput(chunkID: $0.0, meetingID: "m1", version: 0, seq: 0, speaker: $0.1,
                             tStart: 0, tEnd: 1, text: $0.2, contentHash: "blake3:\($0.0)")
        })
        for c in chunks {
            let v = try await embedder.embed([c.2], kind: .document)[0]
            try store.saveEmbedding(chunkID: c.0, space: space, dim: embedder.dim,
                                    modelID: embedder.modelID, vector: v, contentHash: "blake3:\(c.0)")
        }
    }

    private func seedMMR(_ store: Store, space: String) throws {
        let m = Meeting(id: "m_mmr", title: "MMR sync", date: "2026-07-04", source: .paste)
        let chunks: [(id: String, seq: Int, text: String)] = [
            ("c_first", 0, "topic first"),
            ("c_duplicate", 1, "topic duplicate"),
            ("c_diverse", 2, "topic diverse"),
        ]
        try store.saveMeeting(m, chunks: chunks.map {
            Store.ChunkInput(chunkID: $0.id, meetingID: m.id, version: 0, seq: $0.seq,
                             speaker: "T", tStart: Double($0.seq), tEnd: Double($0.seq + 1),
                             text: $0.text, contentHash: "b:\($0.id)")
        })
        let vectors: [(id: String, vector: [Float])] = [
            ("c_first", [0.80, 0.60, 0.00]),
            ("c_duplicate", [0.79, 0.61, 0.00]),
            ("c_diverse", [0.78, -0.62, 0.00]),
        ]
        for row in vectors {
            try store.saveEmbedding(chunkID: row.id, space: space, dim: 3, modelID: "fixed-query",
                                    vector: row.vector, contentHash: "h:\(row.id)")
        }
    }

    private func seedExactKeywordMMR(_ store: Store, space: String) throws {
        let m = Meeting(id: "m_exact_mmr", title: "Exact MMR", date: "2026-07-04", source: .paste)
        let chunks: [(id: String, seq: Int, text: String)] = [
            ("c_exact_keyword", 0, "lodestar keyword appears only in this exact match"),
            ("c_vec_1", 1, "semantic cluster one"),
            ("c_vec_2", 2, "semantic cluster two"),
            ("c_vec_3", 3, "semantic cluster three"),
        ]
        try store.saveMeeting(m, chunks: chunks.map {
            Store.ChunkInput(chunkID: $0.id, meetingID: m.id, version: 0, seq: $0.seq,
                             speaker: "T", tStart: Double($0.seq), tEnd: Double($0.seq + 1),
                             text: $0.text, contentHash: "b:\($0.id)")
        })
        let vectors: [(id: String, vector: [Float])] = [
            ("c_exact_keyword", [0.20, 0.98, 0.00]),
            ("c_vec_1", [1.00, 0.00, 0.00]),
            ("c_vec_2", [0.99, 0.01, 0.00]),
            ("c_vec_3", [0.98, -0.02, 0.00]),
        ]
        for row in vectors {
            try store.saveEmbedding(chunkID: row.id, space: space, dim: 3, modelID: "fixed-query",
                                    vector: row.vector, contentHash: "h:\(row.id)")
        }
    }

    @Test("semantic + keyword fuse: a query surfaces the right chunk")
    func hybridFinds() async throws {
        let store = try freshStore()
        let embedder = StubEmbedder()
        let space = "stub__v1"
        try await seed(store, embedder: embedder, space: space)
        #expect(try store.embeddingCount(space: space) == 3)

        let engine = SearchEngine(store: store, embedder: embedder, space: space)

        // "GPU pricing on Render" hits the render chunk via BOTH lanes → ranks #1.
        let r1 = try await engine.hybrid("Render GPU pricing")
        #expect(r1.first?.chunkID == "c_render")

        // A purely-semantic query ("staking") shares the validator vocab via the doc text token match;
        // confirm the validator chunk ranks above the unrelated ones.
        let r2 = try await engine.hybrid("validator economics")
        #expect(r2.first?.chunkID == "c_val")
    }

    @Test("vector-only hits are hydrated (text returned even without an FTS match)")
    func hydratesVectorOnly() async throws {
        let store = try freshStore()
        let embedder = StubEmbedder()
        let space = "stub__v1"
        try await seed(store, embedder: embedder, space: space)
        let engine = SearchEngine(store: store, embedder: embedder, space: space)

        // "logits" isn't in any chunk's text (no FTS hit) but the query vector still ranks chunks;
        // results must come back hydrated with real text, never empty rows.
        let r = try await engine.hybrid("proof of logits")
        #expect(r.allSatisfy { !$0.text.isEmpty })
    }

    @Test("empty candidate set returns nothing (no out-of-scope leak) — Codex fix")
    func emptyCandidateScopesOut() async throws {
        let store = try freshStore()
        let embedder = StubEmbedder()
        let space = "stub__v1"
        try await seed(store, embedder: embedder, space: space)
        let engine = SearchEngine(store: store, embedder: embedder, space: space)
        let r = try await engine.hybrid("Render GPU pricing", candidateChunkIDs: [])
        #expect(r.isEmpty)
    }

    @Test("candidate set scopes BOTH lanes, not just vector — Codex fix")
    func candidateScopesBothLanes() async throws {
        let store = try freshStore()
        let embedder = StubEmbedder()
        let space = "stub__v1"
        try await seed(store, embedder: embedder, space: space)
        let engine = SearchEngine(store: store, embedder: embedder, space: space)
        // Restrict to the validator chunk only; a Render keyword query must NOT surface c_render via FTS.
        let r = try await engine.hybrid("Render GPU pricing", candidateChunkIDs: ["c_val"])
        #expect(r.allSatisfy { $0.chunkID == "c_val" })
    }

    @Test("MMR picks a diverse passage over a near-duplicate prefix hit")
    func mmrPromotesDiverseCoverage() async throws {
        let store = try freshStore()
        let space = "mmr__v1"
        try seedMMR(store, space: space)
        let query: [Float] = [1, 0, 0]
        let engine = SearchEngine(store: store, embedder: FixedQueryEmbedder(queryVector: query), space: space)

        let plain = VectorMath.topK(query: query, candidates: try store.vectors(space: space),
                                    k: 3, minScore: SearchEngine.vectorFloor).map(\.id)
        #expect(Array(plain.prefix(2)) == ["c_first", "c_duplicate"])

        let hits = try await engine.hybrid("semantic only", ftsLimit: 0, vecLimit: 3, finalLimit: 2)
        #expect(hits.map(\.chunkID) == ["c_first", "c_diverse"])
    }

    @Test("MMR keeps an exact keyword top-RRF hit ahead of a near-duplicate vector cluster")
    func mmrKeepsExactKeywordTopRRFHit() async throws {
        let store = try freshStore()
        let space = "mmr_exact__v1"
        try seedExactKeywordMMR(store, space: space)
        let query: [Float] = [1, 0, 0]
        let engine = SearchEngine(store: store, embedder: FixedQueryEmbedder(queryVector: query), space: space)

        let plainVector = VectorMath.topK(query: query, candidates: try store.vectors(space: space),
                                          k: 4, minScore: SearchEngine.vectorFloor).map(\.id)
        #expect(Array(plainVector.prefix(2)) == ["c_vec_1", "c_vec_2"])

        let hits = try await engine.hybrid("lodestar", ftsLimit: 1, vecLimit: 4, finalLimit: 2)
        #expect(hits.first?.chunkID == "c_exact_keyword")
        #expect(hits.map(\.chunkID).contains("c_exact_keyword"))
    }

    @Test("MMR no-ops to the plain fused prefix when query vector is empty")
    func mmrNoopsWhenQueryVectorEmpty() async throws {
        let store = try freshStore()
        let m = Meeting(id: "m_empty_qv", title: "Empty qv", date: "2026-07-04", source: .paste)
        let chunks: [(id: String, seq: Int, text: String)] = [
            ("c_alpha_1", 0, "alpha alpha alpha"),
            ("c_alpha_2", 1, "alpha alpha"),
            ("c_alpha_3", 2, "alpha"),
        ]
        try store.saveMeeting(m, chunks: chunks.map {
            Store.ChunkInput(chunkID: $0.id, meetingID: m.id, version: 0, seq: $0.seq,
                             speaker: "T", tStart: Double($0.seq), tEnd: Double($0.seq + 1),
                             text: $0.text, contentHash: "b:\($0.id)")
        })
        let expected = Array(try store.keywordSearch("alpha", limit: 3).map(\.chunkID).prefix(2))
        #expect(expected.count == 2)

        let engine = SearchEngine(store: store, embedder: EmptyQueryEmbedder(), space: "empty__v1")
        let hits = try await engine.hybrid("alpha", ftsLimit: 3, vecLimit: 3, finalLimit: 2)
        #expect(hits.map(\.chunkID) == expected)
    }

    // Opt-in live Ollama embedding (needs `ollama serve` + `ollama pull nomic-embed-text`):
    //   CALLBRAIN_LIVE_OLLAMA=1 swift test --filter SearchEngine
    @Test("live Ollama nomic embedding returns a 768-vector",
          .enabled(if: ProcessInfo.processInfo.environment["CALLBRAIN_LIVE_OLLAMA"] == "1"))
    func liveOllama() async throws {
        let e = OllamaEmbedder()
        let v = try await e.embed(["On Render, the GPU spot pricing dropped."], kind: .document)
        #expect(v.count == 1)
        #expect(v[0].count == 768)
    }
}

@Suite("VectorMath top-k floor")
struct VectorFloorTests {
    @Test("minScore drops off-topic (near-zero cosine) hits so they aren't manufactured evidence (A HIGH)")
    func floorDropsOffTopic() {
        let query: [Float] = [1, 0, 0]
        let cands = [("on", [Float](arrayLiteral: 1, 0, 0)),     // cosine 1.0 — real match
                     ("orth", [Float](arrayLiteral: 0, 1, 0)),   // cosine 0.0 — off-topic
                     ("neg", [Float](arrayLiteral: -1, 0, 0))]   // cosine -1.0 — opposite
        let unfiltered = VectorMath.topK(query: query, candidates: cands, k: 3)
        #expect(unfiltered.count == 3)                            // old behavior: returns everything
        let floored = VectorMath.topK(query: query, candidates: cands, k: 3, minScore: 0.15)
        #expect(floored.map(\.id) == ["on"])                     // only the genuine match survives
    }
}
