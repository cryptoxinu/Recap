import Testing
import Foundation
@testable import CallBrainCore

/// Perfection plan Task 5.1a — Ollama-off must never brick Ask (audit CRITICAL P0-7: "Ask AI is
/// completely dead when Ollama is off — instant failure with a lying error"). The keyword lane
/// works without embeddings, so retrieval degrades honestly instead of throwing.
@Suite("Degraded retrieval (embedder down)")
struct DegradedRetrievalTests {

    struct ThrowingEmbedder: Embedder {
        let modelID = "down"
        let dim = 6
        func embed(_ texts: [String], kind: EmbedKind) async throws -> [[Float]] {
            throw EmbedError.http(0)   // connection refused — Ollama not running
        }
    }

    private func seeded(embedder: any Embedder) throws -> SearchEngine {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("cb-degraded-\(UUID().uuidString).sqlite").path
        let store = try Store(path: path)
        let m = Meeting(id: "m1", title: "sync", date: "2026-06-20", source: .fireflies)
        try store.saveMeeting(m, chunks: [Store.ChunkInput(
            chunkID: "c1", meetingID: "m1", version: 0, seq: 0, speaker: "T",
            tStart: 0, tEnd: 1, text: "Riley said the billing pipeline ships Friday",
            contentHash: "b:c1")])
        return SearchEngine(store: store, embedder: embedder, space: "s")
    }

    @Test("hybrid falls back to FTS-only when the embedder is unreachable")
    func testHybridFallsBackToFTSWhenEmbedderFails() async throws {
        let engine = try seeded(embedder: ThrowingEmbedder())
        let r = try await engine.retrieve("riley billing pipeline")
        #expect(!r.hits.isEmpty)                    // keyword lane still answers
        #expect(r.semanticDegraded)                 // and the caller can say so honestly
    }

    @Test("healthy embedder reports no degradation")
    func testHealthyNotDegraded() async throws {
        let engine = try seeded(embedder: StubEmbedder())
        let r = try await engine.retrieve("riley billing")
        #expect(!r.semanticDegraded)
    }
}

/// Task 5.1a — import with the embedder down: text + FTS land, vectors become durable IOUs.
@Suite("Ingest without embedder")
struct IngestWithoutEmbedderTests {
    struct DownEmbedder: Embedder {
        let modelID = "down"; let dim = 6
        func embed(_ texts: [String], kind: EmbedKind) async throws -> [[Float]] { throw EmbedError.http(0) }
    }

    @Test("meeting + chunks + FTS persist; embeddings queue as pending")
    func testIngestPersistsWithoutEmbedder() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("cb-ingest-down-\(UUID().uuidString).sqlite").path
        let store = try Store(path: path)
        let engine = IngestEngine(store: store, embedder: DownEmbedder(), space: "s")
        let parsed = ParsedTranscript(
            title: "Offline import", date: "2026-06-30", source: .paste,
            speakers: ["Riley"],
            utterances: [ParsedUtterance(seq: 0, speakerRaw: "Riley", speakerConfidence: nil,
                                         tStart: 0, tEnd: 5, text: "Billing ships Friday",
                                         isInferredSpeaker: false, tsConfidence: .exact)])
        let outcome = try await engine.ingest(parsed)
        #expect(outcome.chunkCount > 0)
        #expect(outcome.embedded == 0)
        #expect(try !store.keywordSearch("billing", limit: 5).isEmpty)   // searchable NOW
        let pending = try store.pendingEmbeddings()
        #expect(pending.count == outcome.chunkCount)                     // IOUs recorded
        #expect(try store.embeddingCount(space: "s") == 0)
    }
}

/// Task 5.2 — the whole-space vector cache: hit on repeat, invalidated by any write.
@Suite("Vector cache")
struct VectorCacheTests {
    @Test("cache serves repeats and reflects new writes")
    func testCacheInvalidatedOnWrite() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("cb-vcache-\(UUID().uuidString).sqlite").path
        let store = try Store(path: path)
        let m = Meeting(id: "m1", title: "sync", date: "2026-06-20", source: .fireflies)
        try store.saveMeeting(m, chunks: [Store.ChunkInput(
            chunkID: "c1", meetingID: "m1", version: 0, seq: 0, speaker: "T",
            tStart: 0, tEnd: 1, text: "alpha", contentHash: "b:c1")])
        try store.saveEmbedding(chunkID: "c1", space: "s", dim: 2, modelID: "m", vector: [1, 0], contentHash: "h1")
        #expect(try store.cachedVectors(space: "s").count == 1)
        #expect(try store.cachedVectors(space: "s").count == 1)          // repeat — served from cache
        // A new write must invalidate: the next read sees the second vector.
        try store.saveMeeting(m, chunks: [
            Store.ChunkInput(chunkID: "c1", meetingID: "m1", version: 0, seq: 0, speaker: "T",
                             tStart: 0, tEnd: 1, text: "alpha", contentHash: "b:c1"),
            Store.ChunkInput(chunkID: "c2", meetingID: "m1", version: 0, seq: 1, speaker: "T",
                             tStart: 2, tEnd: 3, text: "bravo", contentHash: "b:c2")])
        try store.saveEmbedding(chunkID: "c1", space: "s", dim: 2, modelID: "m", vector: [1, 0], contentHash: "h1")
        try store.saveEmbedding(chunkID: "c2", space: "s", dim: 2, modelID: "m", vector: [0, 1], contentHash: "h2")
        #expect(try store.cachedVectors(space: "s").count == 2)
    }
}
