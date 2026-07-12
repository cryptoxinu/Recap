import Foundation

/// An id with a relevance score (cosine, RRF, etc.), best-first when sorted descending.
public struct ScoredID: Sendable, Equatable {
    public let id: String
    public let score: Double
    public init(id: String, score: Double) { self.id = id; self.score = score }
}

/// Vector math for the V1 brute-force semantic lane (docs/ARCHITECTURE.md §0 D6): embeddings persist as
/// SQLite BLOBs; selective queries do exact cosine over the SQL-filtered candidate set (no ANN recall
/// loss). usearch/sqlite-vec graduate at scale (>~250k chunks).
public enum VectorMath {

    /// Encode a Float32 vector to a little-endian BLOB.
    public static func encode(_ v: [Float]) -> Data {
        var d = Data(capacity: v.count * 4)
        for f in v {
            let le = f.bitPattern.littleEndian
            withUnsafeBytes(of: le) { d.append(contentsOf: $0) }
        }
        return d
    }

    /// Decode a little-endian Float32 BLOB of `dim` elements. Returns nil on a size mismatch.
    public static func decode(_ d: Data, dim: Int) -> [Float]? {
        guard d.count == dim * 4 else { return nil }
        var out = [Float](); out.reserveCapacity(dim)
        var i = d.startIndex
        while i < d.endIndex {
            let bits = UInt32(d[i]) | (UInt32(d[i + 1]) << 8) | (UInt32(d[i + 2]) << 16) | (UInt32(d[i + 3]) << 24)
            out.append(Float(bitPattern: bits))
            i += 4
        }
        return out
    }

    /// Cosine similarity in [-1, 1]. Returns 0 for empty / mismatched / zero-norm vectors.
    public static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in a.indices {
            let x = Double(a[i]), y = Double(b[i])
            dot += x * y; na += x * x; nb += y * y
        }
        let denom = na.squareRoot() * nb.squareRoot()
        return denom == 0 ? 0 : dot / denom
    }

    /// Exact brute-force top-k by cosine. Returns up to `k` `ScoredID`, best-first, dropping any
    /// hit at or below `minScore`. The floor matters: without it an OFF-TOPIC query still returns
    /// its `k` least-dissimilar chunks (cosine ≈ 0 / negative), which the search layer treats as
    /// evidence — manufacturing grounding and defeating the "no evidence → no LLM spend" refusal
    /// (audit A HIGH). A modest floor keeps genuine semantic matches (which score well above it).
    public static func topK(query: [Float], candidates: [(id: String, vector: [Float])], k: Int,
                            minScore: Double = -.infinity) -> [ScoredID] {
        let scored = candidates.map { ScoredID(id: $0.id, score: cosine(query, $0.vector)) }
            .filter { $0.score > minScore }
            .sorted { $0.score > $1.score }
        return Array(scored.prefix(max(0, k)))
    }
}
