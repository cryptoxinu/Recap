import Testing
import Foundation
@testable import CallBrainCore

@Suite("IngestEngine (parse → chunk → embed → store)")
struct IngestEngineTests {

    private func freshStore() throws -> Store {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("cb-ingest-\(UUID().uuidString).sqlite").path
        return try Store(path: path)
    }

    @Test("ingest a Fireflies export end-to-end → stored, embedded, searchable")
    func ingestFireflies() async throws {
        let store = try freshStore()
        let embedder = StubEmbedder()
        let space = "stub__v1"
        let engine = IngestEngine(store: store, embedder: embedder, space: space)

        let outcome = try await engine.ingestFireflies(Data(FirefliesParserTests.sample.utf8))
        #expect(outcome.chunkCount == 3)              // 3 utterances, speaker changes each → 3 chunks
        #expect(outcome.embedded == 3)
        #expect(try store.meetingCount() == 1)
        #expect(try store.embeddingCount(space: space) == 3)

        // searchable through the same engine that powers Ask
        let search = SearchEngine(store: store, embedder: embedder, space: space)
        let hits = try await search.hybrid("inference hardware")
        #expect(hits.contains { $0.text.contains("inference hardware") })
    }

    @Test("ingest a Fathom copy end-to-end")
    func ingestFathom() async throws {
        let store = try freshStore()
        let engine = IngestEngine(store: store, embedder: StubEmbedder(), space: "stub__v1")
        let outcome = try await engine.ingestFathom(FathomParserTests.sample)
        #expect(outcome.chunkCount == 3)
        #expect(outcome.embedded == 3)
        #expect(try store.chunkCount() == 3)
    }

    @Test("content hash is stable for identical text (idempotency foundation)")
    func stableHash() {
        #expect(IngestEngine.sha256("Render") == IngestEngine.sha256("Render"))
        #expect(IngestEngine.sha256("a") != IngestEngine.sha256("b"))
        #expect(IngestEngine.sha256("Render").count == 64)   // hex SHA-256
    }
}
