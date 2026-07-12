import Foundation

/// One labeled question in the retrieval gold set (Phase 0, perfection plan). A question "hits"
/// when any top-k retrieved chunk matches the expectation — by meeting title OR by chunk text
/// (case-insensitive substring). Merge-robustness rule (plan Task 0.2): prefer text anchors, and
/// when titles are used anchor to the transcript-side meeting, never the gemini-notes side.
public struct GoldQuestion: Codable, Sendable, Equatable {
    public let question: String
    public let expectMeetingTitleContains: String?
    public let expectTextContains: String?
    public let dateScope: String?

    public init(question: String, expectMeetingTitleContains: String?,
                expectTextContains: String?, dateScope: String?) {
        self.question = question
        self.expectMeetingTitleContains = expectMeetingTitleContains
        self.expectTextContains = expectTextContains
        self.dateScope = dateScope
    }
}

/// Result of one gold-set run. `hitAtK` is the fraction of questions whose expectation appeared
/// in the top-k hybrid results (0.0 for an empty set — never NaN).
public struct RetrievalEvalResult: Sendable {
    public struct QuestionResult: Sendable {
        public let question: String
        public let hit: Bool
    }
    public let hitAtK: Double
    public let perQuestion: [QuestionResult]
}

/// Runs the gold set through the SAME hybrid retrieval the product uses, so the number moves
/// only when real retrieval quality moves. Pure and deterministic given store + embedder.
public enum RetrievalEval {
    /// `dateScope` format: "YYYY-MM-DD..YYYY-MM-DD" (end EXCLUSIVE) — resolved to a candidate
    /// chunk set exactly like the production date gate (Codex phase-0 MED 4: an eval that
    /// ignores dateScope can't catch date-gating regressions).
    static func candidates(for scope: String?, store: Store) throws -> [String]? {
        guard let scope, !scope.isEmpty else { return nil }
        let parts = scope.components(separatedBy: "..")
        guard parts.count == 2 else { return nil }
        return try store.chunkIDs(fromYMD: parts[0], toYMDExclusive: parts[1])
    }

    public static func run(search: SearchEngine, gold: [GoldQuestion], k: Int) async throws -> RetrievalEvalResult {
        var results: [RetrievalEvalResult.QuestionResult] = []
        for q in gold {
            let cands = try candidates(for: q.dateScope, store: search.store)
            let hits = try await search.hybrid(q.question, candidateChunkIDs: cands, finalLimit: k)
            var matched = false
            for h in hits where !matched {
                if let want = q.expectTextContains, !want.isEmpty,
                   h.text.localizedCaseInsensitiveContains(want) { matched = true }
                if let want = q.expectMeetingTitleContains, !want.isEmpty, !matched,
                   let title = try search.store.meeting(id: h.meetingID)?.title,
                   title.localizedCaseInsensitiveContains(want) { matched = true }
            }
            results.append(.init(question: q.question, hit: matched))
        }
        let rate = results.isEmpty ? 0.0 : Double(results.filter(\.hit).count) / Double(results.count)
        return RetrievalEvalResult(hitAtK: rate, perQuestion: results)
    }
}
