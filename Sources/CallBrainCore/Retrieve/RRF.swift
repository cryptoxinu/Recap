import Foundation

/// Reciprocal Rank Fusion (docs/ARCHITECTURE.md §7.2): merge the keyword (FTS5/BM25) and semantic
/// (vector) ranked lists into one order without comparing their incomparable raw scores.
/// `RRF(d) = Σ_lane  w_lane / (k + rank_lane(d))`, ranks 1-based, default k=60.
public enum RRF {

    /// Fuse ranked id lists (each best-first). `weights` (parallel to `lists`) default to 1.0.
    /// Returns ids fused best-first, with the fused RRF score.
    public static func fuse(_ lists: [[String]], weights: [Double]? = nil, k: Double = 60) -> [ScoredID] {
        var score: [String: Double] = [:]
        for (li, list) in lists.enumerated() {
            let w = weights?.indices.contains(li) == true ? weights![li] : 1.0
            for (rank, id) in list.enumerated() {
                score[id, default: 0] += w / (k + Double(rank + 1))
            }
        }
        // Stable tie-break by id so output is deterministic.
        return score.map { ScoredID(id: $0.key, score: $0.value) }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.id < $1.id }
    }
}
