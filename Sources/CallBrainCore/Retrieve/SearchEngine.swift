import Foundation
import os

/// Hybrid retrieval (docs/ARCHITECTURE.md §7): the keyword/catalogue lane (FTS5/BM25) and the semantic
/// lane (vector cosine) fused by RRF — the "Fireflies catalogue search + AI search, one box" promise.
///
/// V1 vector lane is exact brute-force over the embedding space (optionally a SQL-filtered candidate
/// subset, §0 D6). Hard metadata filters + the QueryPlan are layered on in Phase 4; this is the MVP core.
public struct SearchEngine: Sendable {
    public let store: Store
    public let embedder: any Embedder
    public let space: String

    /// Cosine floor for the vector lane — below this a chunk is not credibly relevant. Conservative
    /// so it prunes off-topic noise without dropping genuine matches (which score well higher).
    static let vectorFloor = 0.15
    /// MMR favors relevance but gives enough weight to diversity to keep near-duplicate chunks from
    /// crowding out adjacent evidence in the final result set.
    static let mmrLambda = 0.7
    private static let mmrCandidateMultiplier = 4
    private static let mmrMaxCandidates = 100

    public init(store: Store, embedder: any Embedder, space: String) {
        self.store = store; self.embedder = embedder; self.space = space
    }

    public struct Result: Sendable, Equatable {
        public let chunkID: String
        public let meetingID: String
        public let speaker: String?
        public let text: String
        public let rrf: Double
        public let tStart: Double?       // chunk start time (s) — threaded to evidence (Task 1.2)
    }

    /// Retrieval outcome: the fused hits + whether the semantic lane was down (Task 5.1a — the
    /// reasoning timeline says "Semantic search paused" honestly instead of Ask bricking).
    public struct Retrieval: Sendable {
        public let hits: [Result]
        public let semanticDegraded: Bool
    }

    /// Fuse keyword + semantic retrieval. `candidateChunkIDs` (when provided) pre-filters the vector
    /// lane to an in-scope subset for exact recall under selective filters.
    /// Back-compat wrapper — callers that don't care about degradation keep their signature.
    public func hybrid(_ query: String, candidateChunkIDs: [String]? = nil,
                       ftsLimit: Int = 50, vecLimit: Int = 50, finalLimit: Int = 20,
                       weights: [Double]? = nil) async throws -> [Result] {
        try await retrieve(query, candidateChunkIDs: candidateChunkIDs, ftsLimit: ftsLimit,
                           vecLimit: vecLimit, finalLimit: finalLimit, weights: weights).hits
    }

    public func retrieve(_ query: String, candidateChunkIDs: [String]? = nil,
                         ftsLimit: Int = 50, vecLimit: Int = 50, finalLimit: Int = 20,
                         weights: [Double]? = nil, speakerBoost: String? = nil) async throws -> Retrieval {
        // Hard-filter candidate set applies to BOTH lanes IN SQL before LIMIT (Codex audit fix):
        // scoped recall is exact, and an empty set yields no results from either lane.
        let ftsHits = try store.keywordSearch(query, limit: ftsLimit, candidateChunkIDs: candidateChunkIDs)
        let ftsRanked = ftsHits.map(\.chunkID)

        // Semantic lane: embed the query with the SAME model, exact cosine over the candidate
        // vectors. Document embeddings carry only a compact metadata header, so the query stays
        // bare; adding a neutral query header would dilute short natural questions more than it helps.
        // An UNREACHABLE embedder (Ollama off) degrades to keyword-only — the audit's P0-7 CRITICAL
        // was this exact throw bricking Ask and import.
        var semanticDegraded = false
        var qv: [Float] = []
        do { qv = try await embedder.embed([query], kind: .query).first ?? [] }
        catch is CancellationError { throw CancellationError() }   // Stop must STOP (gate HIGH:
                                                                   // degrading a cancelled ask
                                                                   // would burn an LLM call)
        catch { semanticDegraded = true }
        let cands: [(id: String, vector: [Float])]
        if qv.isEmpty { cands = [] }
        else if candidateChunkIDs == nil { cands = try store.cachedVectors(space: space) }   // Task 5.2
        else { cands = try store.vectors(space: space, chunkIDs: candidateChunkIDs) }
        // A modest cosine floor so an off-topic query yields NO vector evidence (audit A HIGH) —
        // genuine matches score well above it; the FTS lane still carries keyword hits.
        let vecRanked = VectorMath.topK(query: qv, candidates: cands, k: vecLimit,
                                        minScore: Self.vectorFloor).map(\.id)

        // Person-boost lane (Task 6.2): a SOFT third RRF list of the named speaker's chunks —
        // boosts, never hard-filters, until speaker naming lands (Phase 8) and labels are clean.
        var lanes = [ftsRanked, vecRanked]
        var laneWeights = weights ?? [1, 1]
        if let speakerBoost, !speakerBoost.isEmpty {
            do {
                let boosted = try store.chunkIDs(speakerContains: speakerBoost)
                if !boosted.isEmpty {
                    let allowed = candidateChunkIDs.map(Set.init)
                    lanes.append(allowed == nil ? boosted : boosted.filter { allowed!.contains($0) })
                    laneWeights.append(0.5)
                }
            } catch {
                // Boost is an enhancement — don't kill the ask, but never hide a DB read
                // failure either (gate MED).
                Logger(subsystem: "com.callbrain", category: "retrieve")
                    .error("person-boost lane failed: \(error.localizedDescription)")
            }
        }

        // Fuse, MMR-rerank when vectors are available, then hydrate.
        let fused = RRF.fuse(lanes, weights: laneWeights)
        let selected = mmrRerankedOrPrefix(fused, queryVector: qv, finalLimit: finalLimit)
        guard !selected.isEmpty else { return Retrieval(hits: [], semanticDegraded: semanticDegraded) }

        var byID: [String: Store.ChunkHit] = [:]
        for h in ftsHits { byID[h.chunkID] = h }
        // Vector-only hits need hydration too.
        let missing = selected.map(\.id).filter { byID[$0] == nil }
        for h in try store.chunks(ids: missing) { byID[h.chunkID] = h }

        let hits = selected.compactMap { s -> Result? in
            guard let h = byID[s.id] else { return nil }
            return Result(chunkID: h.chunkID, meetingID: h.meetingID, speaker: h.speaker,
                          text: h.text, rrf: s.score, tStart: h.tStart)
        }
        return Retrieval(hits: hits, semanticDegraded: semanticDegraded)
    }

    /// Max cosine of `query` to any chunk of each meeting — an ABSOLUTE per-meeting semantic relevance for
    /// prep matching (FIX 6). Absolute (not relative RRF), so a fixed floor means the same thing across
    /// queries. Returns [:] when the embedder is down (Ollama off) so prep degrades to lexical matching.
    public func meetingRelevance(_ query: String, topChunks: Int = 400) async throws -> [String: Double] {
        let qv: [Float]
        do { qv = try await embedder.embed([query], kind: .query).first ?? [] }
        catch is CancellationError { throw CancellationError() }
        catch { return [:] }   // embedder unreachable → no semantic lane, caller keeps lexical candidates
        guard !qv.isEmpty else { return [:] }
        try Task.checkCancellation()   // reloaded/dismissed prep card → bail BEFORE the full-corpus scan
        let cands = try store.cachedVectors(space: space)
        let scored = VectorMath.topK(query: qv, candidates: cands, k: topChunks, minScore: Self.vectorFloor)
        guard !scored.isEmpty else { return [:] }
        let cosByChunk = Dictionary(scored.map { ($0.id, $0.score) }, uniquingKeysWith: { first, _ in first })
        var maxByMeeting: [String: Double] = [:]
        for h in try store.chunks(ids: scored.map(\.id)) {
            guard let c = cosByChunk[h.chunkID] else { continue }
            maxByMeeting[h.meetingID] = max(maxByMeeting[h.meetingID] ?? 0, c)
        }
        return maxByMeeting
    }

    private func mmrRerankedOrPrefix(_ fused: [ScoredID], queryVector qv: [Float],
                                     finalLimit: Int) -> [ScoredID] {
        let plainPrefix = Array(fused.prefix(max(0, finalLimit)))
        guard !qv.isEmpty, !plainPrefix.isEmpty else { return plainPrefix }

        let pool = Array(fused.prefix(Self.mmrCandidateLimit(finalLimit: finalLimit)))
        do {
            let vectors = try store.vectors(space: space, chunkIDs: pool.map(\.id))
            // uniquingKeysWith (not uniqueKeysWithValues) — a duplicate chunk id from the store must
            // not fatalError the whole retrieval; keep the first vector (audit LOW).
            let vectorsByID = Dictionary(vectors.map { ($0.id, $0.vector) }, uniquingKeysWith: { first, _ in first })
            guard vectorsByID.count == pool.count else { return plainPrefix }
            return Self.mmrSelect(candidates: pool, queryVector: qv,
                                  normalizedRRFByID: Self.normalizedRRFByID(pool),
                                  vectorsByID: vectorsByID, limit: finalLimit)
        } catch {
            Logger(subsystem: "com.callbrain", category: "retrieve")
                .error("MMR vector hydration failed; falling back to prefix: \(error.localizedDescription)")
            return plainPrefix
        }
    }

    static func mmrSelect(candidates: [ScoredID], queryVector qv: [Float],
                          normalizedRRFByID: [String: Double],
                          vectorsByID: [String: [Float]], limit: Int) -> [ScoredID] {
        let plainPrefix = Array(candidates.prefix(max(0, limit)))
        guard !qv.isEmpty, !plainPrefix.isEmpty,
              Set(candidates.map(\.id)).allSatisfy({ vectorsByID[$0] != nil })
        else { return plainPrefix }

        var selected: [ScoredID] = []
        var remaining = candidates
        var maxSimilarityByID: [String: Double] = [:]
        while selected.count < limit, !remaining.isEmpty {
            let bestIndex = remaining.indices.max { lhs, rhs in
                let left = Self.mmrScore(candidate: remaining[lhs],
                                         normalizedRRF: normalizedRRFByID[remaining[lhs].id] ?? 0,
                                         maxSimilarity: maxSimilarityByID[remaining[lhs].id] ?? 0,
                                         vectorsByID: vectorsByID)
                let right = Self.mmrScore(candidate: remaining[rhs],
                                          normalizedRRF: normalizedRRFByID[remaining[rhs].id] ?? 0,
                                          maxSimilarity: maxSimilarityByID[remaining[rhs].id] ?? 0,
                                          vectorsByID: vectorsByID)
                return left == right ? lhs > rhs : left < right
            } ?? remaining.startIndex
            let picked = remaining.remove(at: bestIndex)
            selected.append(picked)
            if let pickedVector = vectorsByID[picked.id] {
                maxSimilarityByID = Dictionary(uniqueKeysWithValues: candidates.map { candidate in
                    let id = candidate.id
                    guard let vector = vectorsByID[id] else { return (id, maxSimilarityByID[id] ?? 0) }
                    let similarity = VectorMath.cosine(vector, pickedVector)
                    let updated = maxSimilarityByID[id].map { max($0, similarity) } ?? similarity
                    return (id, updated)
                })
            }
        }
        return selected
    }

    private static func mmrScore(candidate: ScoredID, normalizedRRF: Double,
                                 maxSimilarity: Double, vectorsByID: [String: [Float]]) -> Double {
        guard vectorsByID[candidate.id] != nil else { return -.infinity }
        return mmrLambda * normalizedRRF - (1 - mmrLambda) * maxSimilarity
    }

    private static func normalizedRRFByID(_ candidates: [ScoredID]) -> [String: Double] {
        let maxScore = candidates.map(\.score).max() ?? 0
        guard maxScore > 0 else {
            return Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, 0.0) })
        }
        return Dictionary(uniqueKeysWithValues: candidates.map {
            ($0.id, min(1, max(0, $0.score / maxScore)))
        })
    }

    private static func mmrCandidateLimit(finalLimit: Int) -> Int {
        guard finalLimit > 0 else { return 0 }
        return max(finalLimit, min(mmrMaxCandidates, finalLimit * mmrCandidateMultiplier))
    }
}
