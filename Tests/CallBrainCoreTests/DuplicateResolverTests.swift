import Testing
import Foundation
@testable import CallBrainCore

@Suite("DuplicateResolver (one-click AI cleanup plan)")
struct DuplicateResolverTests {

    private func q(_ id: String, source: String = "fathom", chunks: Int = 0, tasks: Int = 0,
                   summary: Bool = false, aiTitle: Bool = true, dur: Double = 0, title: String? = nil)
        -> DuplicateResolver.MeetingQuality {
        DuplicateResolver.MeetingQuality(
            id: id, title: title ?? "Call \(id)", source: source, date: "2026-06-29",
            chunkCount: chunks, taskCount: tasks, hasFullSummary: summary, hasAITitle: aiTitle, durationSec: dur)
    }

    private func edge(_ a: String, _ b: String, cross: Bool = true, score: Double = 0.9,
                      kind: DuplicateResolver.Edge.Kind = .suggestion) -> DuplicateResolver.Edge {
        DuplicateResolver.Edge(a: a, b: b, crossSource: cross, score: score, kind: kind)
    }

    @Test("richer transcript survives; the note is folded in")
    func richerSurvives() {
        let quality = ["note": q("note", source: "gmeet_gemini", chunks: 2, summary: true, aiTitle: true),
                       "rec": q("rec", source: "fathom", chunks: 40, tasks: 5, summary: true, dur: 3600)]
        let plan = DuplicateResolver.plan(edges: [edge("note", "rec")], quality: quality)
        #expect(plan.merges.count == 1)
        #expect(plan.merges[0].survivorID == "rec")
        #expect(plan.merges[0].loserID == "note")
        #expect(plan.mergedAwayCount == 1)
    }

    @Test("a chain A~B~C keeps ONE survivor and merges the other two into it")
    func transitiveCluster() {
        let quality = ["a": q("a", chunks: 5), "b": q("b", chunks: 50), "c": q("c", chunks: 10)]
        let edges = [edge("a", "b"), edge("b", "c")]
        let plan = DuplicateResolver.plan(edges: edges, quality: quality)
        #expect(plan.merges.count == 2)
        // b is richest → survivor of the whole cluster; nobody merges INTO a loser.
        #expect(plan.merges.allSatisfy { $0.survivorID == "b" })
        #expect(Set(plan.merges.map(\.loserID)) == ["a", "c"])
    }

    @Test("low-confidence same-source title match is NOT auto-merged — it goes to review")
    func weakGoesToReview() {
        let quality = ["x": q("x", source: "fathom", chunks: 10), "y": q("y", source: "fathom", chunks: 12)]
        // same-source (cross=false), weak score → not auto-applied
        let plan = DuplicateResolver.plan(edges: [edge("x", "y", cross: false, score: 0.62)], quality: quality)
        #expect(plan.merges.isEmpty)
        #expect(plan.reviewCount == 1)
    }

    @Test("notes↔recording LINK always auto-merges regardless of score")
    func linkAlwaysAuto() {
        let quality = ["g": q("g", source: "gmeet_gemini", chunks: 1),
                       "t": q("t", source: "gmeet_local", chunks: 30)]
        let plan = DuplicateResolver.plan(edges: [edge("g", "t", cross: true, score: 0.1, kind: .link)],
                                          quality: quality)
        #expect(plan.merges.count == 1)
        #expect(plan.merges[0].survivorID == "t")
    }

    @Test("an edge whose meeting has no quality signal is not merged, but still surfaces for review (never vanishes)")
    func missingQualitySkipped() {
        let quality = ["a": q("a", chunks: 10)]   // "b" unknown
        let plan = DuplicateResolver.plan(edges: [edge("a", "b")], quality: quality)
        #expect(plan.merges.isEmpty)
        #expect(plan.reviewCount == 1)   // dropped from auto-merge → must still be reviewable, not silently gone
    }

    @Test("no edge is a loser in two merges (each meeting merged at most once)")
    func eachLoserOnce() {
        let quality = ["a": q("a", chunks: 100), "b": q("b", chunks: 5),
                       "c": q("c", chunks: 6), "d": q("d", chunks: 7)]
        // a connects to b, c, d (star) — all should fold into a exactly once.
        let edges = [edge("a", "b"), edge("a", "c"), edge("a", "d")]
        let plan = DuplicateResolver.plan(edges: edges, quality: quality)
        let losers = plan.merges.map(\.loserID)
        #expect(Set(losers).count == losers.count)          // no duplicates
        #expect(plan.merges.allSatisfy { $0.survivorID == "a" })
    }
}
