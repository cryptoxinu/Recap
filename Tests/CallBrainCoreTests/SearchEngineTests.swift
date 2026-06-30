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
            ("c_render", "Travis", "On Render, the GPU spot pricing dropped this week."),
            ("c_val",    "Max",    "Validators stake to secure the network economics."),
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
