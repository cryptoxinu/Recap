import Testing
import Foundation
@testable import CallBrainCore

@Suite("Vector math")
struct VectorMathTests {

    @Test("Float32 BLOB encode/decode round-trips exactly")
    func blobRoundTrip() {
        let v: [Float] = [0.0, 1.0, -2.5, 3.14159, 1_000.5]
        let blob = VectorMath.encode(v)
        #expect(blob.count == v.count * 4)
        #expect(VectorMath.decode(blob, dim: v.count) == v)
        #expect(VectorMath.decode(blob, dim: 99) == nil)      // size guard
    }

    @Test("cosine: identical = 1, orthogonal = 0, opposite = -1")
    func cosine() {
        #expect(abs(VectorMath.cosine([1, 0, 0], [1, 0, 0]) - 1.0) < 1e-9)
        #expect(abs(VectorMath.cosine([1, 0], [0, 1]) - 0.0) < 1e-9)
        #expect(abs(VectorMath.cosine([1, 0], [-1, 0]) - (-1.0)) < 1e-9)
        #expect(VectorMath.cosine([], []) == 0)               // degenerate
        #expect(VectorMath.cosine([1, 2], [1, 2, 3]) == 0)    // mismatch
    }

    @Test("topK ranks by cosine, best-first, capped at k")
    func topK() {
        let q: [Float] = [1, 0]
        let cands: [(id: String, vector: [Float])] = [
            ("a", [1, 0]),      // cos 1
            ("b", [0.7, 0.7]),  // ~0.707
            ("c", [-1, 0]),     // -1
        ]
        let top = VectorMath.topK(query: q, candidates: cands, k: 2)
        #expect(top.map(\.id) == ["a", "b"])
        #expect(top.count == 2)
    }
}

@Suite("RRF fusion")
struct RRFTests {

    @Test("an id ranked highly in both lanes wins")
    func consensusWins() {
        let fts = ["x", "a", "b"]      // a is #2
        let vec = ["y", "a", "c"]      // a is #2 again
        let fused = RRF.fuse([fts, vec])
        #expect(fused.first?.id == "a")            // appears in both → highest fused score
    }

    @Test("weights bias a lane")
    func weighting() {
        let fts = ["a", "z"]           // a #1, z #2
        let vec = ["b", "a"]           // b #1, a #2
        // Heavily weight the keyword lane → its #1 (a) should beat vec's #1 (b).
        let fused = RRF.fuse([fts, vec], weights: [3.0, 1.0])
        #expect(fused.first?.id == "a")
    }

    @Test("deterministic tie-break by id")
    func deterministic() {
        let fused = RRF.fuse([["a"], ["b"]])       // a and b each rank-1 in one list → equal score
        #expect(fused.map(\.id) == ["a", "b"])     // tie broken a < b
    }
}
