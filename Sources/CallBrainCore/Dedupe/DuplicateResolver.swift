import Foundation

/// One-click "Clean up duplicates with AI" (2026-07-09). Turns the heuristic duplicate *suggestions* +
/// notes↔recording *links* into a concrete, content-conserving cleanup PLAN: for each cluster of duplicate
/// copies of the same call, keep the highest-quality copy and MERGE the rest into it (via the audited
/// `Store.mergeMeetings`, which conserves transcript/notes/tasks/citations). Nothing is ever blind-deleted,
/// so "one click" is safe — zero data loss. Low-confidence pairs are left for the user to review by hand.
///
/// Pure over injected data (quality signals + the pair graph), so it's fully unit-testable and never
/// touches a live Store or an LLM. "AI" here = deterministic quality judgement, which for an
/// irreversible-adjacent bulk action is the right call (defensible, instant, no hallucinated deletes).
public enum DuplicateResolver {

    /// Everything the resolver needs to know about one meeting to judge which copy is richer.
    /// The app fills this from the meeting row + one batched signals query (`Store.meetingQualitySignals`).
    public struct MeetingQuality: Sendable, Equatable {
        public let id: String
        public let title: String        // displayTitle (AI title when present)
        public let source: String
        public let date: String         // "YYYY-MM-DD"
        public let chunkCount: Int      // transcript richness — the dominant signal
        public let taskCount: Int       // extracted action items
        public let hasFullSummary: Bool // a full call_summary was generated
        public let hasAITitle: Bool     // got a meaningful name (not a date stamp)
        public let durationSec: Double   // longest utterance end, 0 when unknown
        public init(id: String, title: String, source: String, date: String, chunkCount: Int,
                    taskCount: Int, hasFullSummary: Bool, hasAITitle: Bool, durationSec: Double) {
            self.id = id; self.title = title; self.source = source; self.date = date
            self.chunkCount = chunkCount; self.taskCount = taskCount
            self.hasFullSummary = hasFullSummary; self.hasAITitle = hasAITitle
            self.durationSec = durationSec
        }

        /// Source fidelity tier: a full recording/transcript beats meeting notes beats pasted text — used
        /// as a small weight AND the final tie-breaker so, all else equal, the fuller-fidelity copy survives.
        public var sourceTier: Int {
            switch source {
            case "gmeet_local", "gmeet_cloud", "fireflies", "fathom", "cluely", "gmeet_captions": 2
            case "gmeet_gemini": 1        // AI notes — real content, but a summary of the call, not the call
            default: 0                    // paste / unknown
            }
        }

        /// Composite quality score. Transcript richness dominates (chunkCount), with real bonuses for a
        /// generated summary + extracted tasks, and duration/source as secondary. Deterministic + monotone.
        public var score: Double {
            Double(chunkCount) * 1.0
                + (hasFullSummary ? 8 : 0)
                + Double(taskCount) * 2.0
                + min(durationSec / 60.0, 180) * 0.25
                + Double(sourceTier) * 5.0
                + (hasAITitle ? 2 : 0)
        }
    }

    /// A duplicate relationship between two meetings, with the confidence signal that decides whether it's
    /// safe to auto-merge. `crossSource` (the same call captured by two different tools) is the strongest
    /// "definitely the same call" signal; a pure title match needs to be near-identical to auto-apply.
    public struct Edge: Sendable, Equatable {
        public enum Kind: Sendable, Equatable { case link, suggestion }
        public let a: String
        public let b: String
        public let crossSource: Bool
        public let score: Double        // 0…1 pair-match strength
        public let kind: Kind
        public init(a: String, b: String, crossSource: Bool, score: Double, kind: Kind) {
            self.a = a; self.b = b; self.crossSource = crossSource; self.score = score; self.kind = kind
        }
        /// Auto-apply only high-confidence pairs. A notes↔recording LINK is by construction the two halves
        /// of one call → always. A near-duplicate SUGGESTION is auto when it's cross-source (two tools, one
        /// call) OR its titles are near-identical (≥0.78); weaker matches go to manual review.
        public var autoApply: Bool {
            switch kind {
            case .link: return true
            case .suggestion: return crossSource || score >= 0.78
            }
        }
    }

    /// One planned merge: fold `loser` into `survivor` (the higher-quality copy). Content-conserving.
    public struct PlannedMerge: Sendable, Equatable, Identifiable {
        public let survivorID: String
        public let loserID: String
        public let survivorTitle: String
        public let loserTitle: String
        public let survivorDetail: String    // e.g. "Fathom · 89 min · 210 segments"
        public let loserDetail: String
        public let reason: String            // human one-liner shown in the preview
        public var id: String { "\(loserID)->\(survivorID)" }
    }

    public struct CleanupPlan: Sendable, Equatable {
        public let merges: [PlannedMerge]
        public let reviewCount: Int          // low-confidence pairs left for manual review
        public var isEmpty: Bool { merges.isEmpty }
        /// Distinct meetings that disappear (get merged away) — the honest "N duplicates cleaned" count.
        public var mergedAwayCount: Int { Set(merges.map(\.loserID)).count }
    }

    /// Build the cleanup plan. `edges` is the duplicate graph (from links + suggestions); `quality` maps
    /// every referenced meeting id to its quality signals. Clusters the auto-apply edges into connected
    /// components (so a chain A~B~C keeps ONE survivor and never merges into a meeting that itself got
    /// merged away), picks the richest copy per cluster, and emits loser→survivor merges.
    public static func plan(edges: [Edge], quality: [String: MeetingQuality]) -> CleanupPlan {
        // Only cluster edges we can actually act on: auto-apply AND both endpoints have known quality.
        let auto = edges.filter { $0.autoApply && quality[$0.a] != nil && quality[$0.b] != nil }

        // Union-find over the auto edges.
        var parent: [String: String] = [:]
        func find(_ x: String) -> String {
            var r = x
            while let p = parent[r], p != r { r = p }
            // path-compress
            var cur = x
            while let p = parent[cur], p != r { parent[cur] = r; cur = p }
            return r
        }
        func union(_ x: String, _ y: String) {
            parent[x] = parent[x] ?? x; parent[y] = parent[y] ?? y
            let rx = find(x), ry = find(y)
            guard rx != ry else { return }
            // Attach the lower-quality root under the higher-quality one so the survivor stays the root.
            let sx = quality[rx]?.score ?? 0, sy = quality[ry]?.score ?? 0
            if sx >= sy { parent[ry] = rx } else { parent[rx] = ry }
        }
        for e in auto { union(e.a, e.b) }

        // Group members by their component root.
        var components: [String: [String]] = [:]
        var members = Set<String>()
        for e in auto { members.insert(e.a); members.insert(e.b) }
        for m in members { components[find(m), default: []].append(m) }

        var merges: [PlannedMerge] = []
        for (_, ids) in components {
            // Survivor = highest score; deterministic tie-break by (chunkCount, duration, id).
            let survivor = ids.max(by: { lhs, rhs in less(quality[lhs]!, quality[rhs]!) })!
            let losers = ids.filter { $0 != survivor }.sorted()
            let sq = quality[survivor]!
            for loser in losers {
                let lq = quality[loser]!
                merges.append(PlannedMerge(
                    survivorID: survivor, loserID: loser,
                    survivorTitle: sq.title, loserTitle: lq.title,
                    survivorDetail: detail(sq), loserDetail: detail(lq),
                    reason: reason(keep: sq, drop: lq)))
            }
        }
        // Stable, human-friendly ordering: by survivor title then loser title.
        merges.sort { ($0.survivorTitle, $0.loserTitle) < ($1.survivorTitle, $1.loserTitle) }

        // Review = every duplicate pair NOT resolved by a merge (both endpoints folded into the same
        // survivor → nothing left to review). This deliberately does NOT special-case `autoApply`: a
        // high-confidence edge that was dropped from `auto` because one endpoint had no quality signal
        // (e.g. a meeting changed between the edge scan and the quality read) must still surface for a
        // human — it would otherwise vanish entirely (not merged, not shown). Verified: review-audit MED.
        let mergedInto: [String: String] = {
            var out: [String: String] = [:]
            for m in merges { out[m.loserID] = m.survivorID; out[m.survivorID] = m.survivorID }
            return out
        }()
        let review = edges.filter { e in
            let ra = mergedInto[e.a] ?? e.a, rb = mergedInto[e.b] ?? e.b
            return ra != rb        // still two distinct meetings → worth a human look
        }
        return CleanupPlan(merges: merges, reviewCount: review.count)
    }

    // MARK: - helpers

    /// Strict "lower quality than" for tie-broken survivor selection (higher is better).
    static func less(_ a: MeetingQuality, _ b: MeetingQuality) -> Bool {
        if a.score != b.score { return a.score < b.score }
        if a.chunkCount != b.chunkCount { return a.chunkCount < b.chunkCount }
        if a.durationSec != b.durationSec { return a.durationSec < b.durationSec }
        return a.id > b.id     // stable: earlier id wins ties
    }

    static func detail(_ q: MeetingQuality) -> String {
        var parts: [String] = [label(q.source)]
        if q.durationSec >= 60 { parts.append("\(Int((q.durationSec / 60).rounded())) min") }
        if q.chunkCount > 0 { parts.append("\(q.chunkCount) segment\(q.chunkCount == 1 ? "" : "s")") }
        else if q.hasFullSummary { parts.append("summary") }
        return parts.joined(separator: " · ")
    }

    /// A one-line, plain-English rationale for the founder — WHY this copy is the keeper.
    static func reason(keep: MeetingQuality, drop: MeetingQuality) -> String {
        if keep.chunkCount > drop.chunkCount + 1 {
            return "Keeping the fuller transcript (\(keep.chunkCount) vs \(drop.chunkCount) segments)."
        }
        if keep.hasFullSummary && !drop.hasFullSummary { return "Keeping the copy with a full summary." }
        if keep.taskCount > drop.taskCount { return "Keeping the copy with more action items." }
        if keep.sourceTier > drop.sourceTier { return "Keeping the \(label(keep.source)) copy over the \(label(drop.source))." }
        if keep.durationSec > drop.durationSec + 60 { return "Keeping the longer recording." }
        return "Both look equivalent — keeping one, combining the content."
    }

    static func label(_ source: String) -> String {
        switch source {
        case "gmeet_gemini": "Google Meet notes"
        case "gmeet_captions": "Meet captions"
        case "gmeet_local", "gmeet_cloud": "recording"
        case "fireflies": "Fireflies"; case "fathom": "Fathom"; case "cluely": "Cluely"
        case "paste": "pasted text"; default: source
        }
    }
}
