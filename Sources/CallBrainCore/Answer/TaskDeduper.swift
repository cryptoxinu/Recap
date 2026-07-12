import Foundation

/// Groups the SAME to-do that shows up across several calls in different words ("Migrate the Notion docs
/// to a site" / "Update Docs: migrate from Notion to a hardcoded site" / "Move docs to a version-controlled
/// website") into one cluster — so the Tasks list shows it ONCE instead of three times. Deterministic, no
/// AI, at display time (like `OwnerResolver`), so it collapses the existing list with no re-import and no
/// data change (the rows stay; the UI just folds the near-duplicates behind a representative).
///
/// Deliberately CONSERVATIVE (high precision): it folds only NEAR-IDENTICAL repeats — an exact restatement,
/// or a shorter task fully subsumed by a longer one ("Update pricing" ⊂ "Update pricing information in the
/// new website design"). It does NOT try to merge reworded-same-intent tasks that share few words
/// ("Migrate docs to a site" vs "Merge the Notion docs into GitHub"), because token overlap can't tell a
/// genuine reword from two DIFFERENT tasks ("Review the billing PR" vs "the routing PR" share 3 words) —
/// and hiding a real distinct task is worse than showing a duplicate. Those reworded dups are the job of
/// "Tidy with AI", which has the LLM judgment to merge them safely (mark-done, reversible).
public enum TaskDeduper {

    /// High-precision fold bar: near-containment / near-exact. Above the strict-dedup bar so distinct
    /// tasks that merely share a few words are never merged.
    static let foldThreshold = 0.85

    /// A cluster of task rows that are the same underlying to-do. `representativeID` is the row the UI
    /// shows (the most-complete wording); `memberIDs` are ALL rows in the cluster (incl. the representative)
    /// so a one-tap "done" can resolve every copy at once.
    public struct Cluster: Sendable, Equatable {
        public let representativeID: String
        public let memberIDs: [String]
        public var count: Int { memberIDs.count }
        public init(representativeID: String, memberIDs: [String]) {
            self.representativeID = representativeID; self.memberIDs = memberIDs
        }
    }

    /// Cluster near-duplicate tasks. Input is (id, text); `id` order is made deterministic internally so the
    /// result never depends on caller ordering. Singletons (unique tasks) come back as 1-member clusters.
    /// The representative is the LONGEST text in the cluster (most complete), ties broken by id — stable.
    public static func cluster(_ tasks: [(id: String, text: String)]) -> [Cluster] {
        // Deterministic seed order: longest text first (best representative), then id.
        let ordered = tasks.sorted { a, b in
            a.text.count != b.text.count ? a.text.count > b.text.count : a.id < b.id
        }
        var buckets: [[(id: String, text: String)]] = []
        for t in ordered {
            if let i = buckets.firstIndex(where: { bucket in
                TaskIntelligence.isNearDuplicate(t.text, of: bucket.map(\.text), threshold: foldThreshold, strict: false)
            }) {
                buckets[i].append(t)
            } else {
                buckets.append([t])
            }
        }
        return buckets.map { bucket in
            // Representative = first (longest, then lowest id — the seed of the bucket).
            Cluster(representativeID: bucket[0].id, memberIDs: bucket.map(\.id))
        }
    }

    /// Convenience: representative-id → the cluster's other member ids, plus the display count. Only clusters
    /// with >1 member are returned; a caller hides non-representative members and badges the representative.
    public static func foldMap(_ tasks: [(id: String, text: String)]) -> (hidden: Set<String>, byRep: [String: [String]]) {
        var hidden = Set<String>()
        var byRep: [String: [String]] = [:]
        for c in cluster(tasks) where c.count > 1 {
            byRep[c.representativeID] = c.memberIDs
            for id in c.memberIDs where id != c.representativeID { hidden.insert(id) }
        }
        return (hidden, byRep)
    }
}
