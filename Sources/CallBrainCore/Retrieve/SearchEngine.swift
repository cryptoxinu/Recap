import Foundation

/// Hybrid retrieval (docs/ARCHITECTURE.md §7): the keyword/catalogue lane (FTS5/BM25) and the semantic
/// lane (vector cosine) fused by RRF — the "Fireflies catalogue search + AI search, one box" promise.
///
/// V1 vector lane is exact brute-force over the embedding space (optionally a SQL-filtered candidate
/// subset, §0 D6). Hard metadata filters + the QueryPlan are layered on in Phase 4; this is the MVP core.
public struct SearchEngine: Sendable {
    public let store: Store
    public let embedder: any Embedder
    public let space: String

    public init(store: Store, embedder: any Embedder, space: String) {
        self.store = store; self.embedder = embedder; self.space = space
    }

    public struct Result: Sendable, Equatable {
        public let chunkID: String
        public let meetingID: String
        public let speaker: String?
        public let text: String
        public let rrf: Double
    }

    /// Fuse keyword + semantic retrieval. `candidateChunkIDs` (when provided) pre-filters the vector
    /// lane to an in-scope subset for exact recall under selective filters.
    public func hybrid(_ query: String, candidateChunkIDs: [String]? = nil,
                       ftsLimit: Int = 50, vecLimit: Int = 50, finalLimit: Int = 20,
                       weights: [Double]? = nil) async throws -> [Result] {
        // Keyword lane (synchronous, indexed).
        let ftsHits = try store.keywordSearch(query, limit: ftsLimit)
        let ftsRanked = ftsHits.map(\.chunkID)

        // Semantic lane: embed the query with the SAME model, exact cosine over the candidate vectors.
        let qv = try await embedder.embed([query], kind: .query).first ?? []
        let cands = qv.isEmpty ? [] : try store.vectors(space: space, chunkIDs: candidateChunkIDs)
        let vecRanked = VectorMath.topK(query: qv, candidates: cands, k: vecLimit).map(\.id)

        // Fuse and hydrate.
        let fused = Array(RRF.fuse([ftsRanked, vecRanked], weights: weights).prefix(finalLimit))
        guard !fused.isEmpty else { return [] }

        var byID: [String: Store.ChunkHit] = [:]
        for h in ftsHits { byID[h.chunkID] = h }
        // Vector-only hits need hydration too.
        let missing = fused.map(\.id).filter { byID[$0] == nil }
        for h in try store.chunks(ids: missing) { byID[h.chunkID] = h }

        return fused.compactMap { s in
            guard let h = byID[s.id] else { return nil }
            return Result(chunkID: h.chunkID, meetingID: h.meetingID, speaker: h.speaker,
                          text: h.text, rrf: s.score)
        }
    }
}
