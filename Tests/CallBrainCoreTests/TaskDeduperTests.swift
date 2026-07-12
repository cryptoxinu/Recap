import Testing
@testable import CallBrainCore

/// Cross-call task de-duplication (founder: "certain tasks might be repeated in other calls — is the
/// system smart enough?"). CONSERVATIVE by design: fold only near-identical repeats; NEVER hide a real
/// distinct task (over-merging is worse than a visible dup). Reworded-same-intent merges are Tidy-with-AI's
/// job. These lock both the fold and the safety boundary.
@Suite("TaskDeduper — cross-call near-duplicate folding (conservative)")
struct TaskDeduperTests {

    @Test("a shorter task fully subsumed by a longer one folds into it")
    func foldsContainment() {
        let tasks = [
            ("short", "Update pricing"),
            ("long", "Update pricing information in the new website design"),
            ("other", "Send Junney a full blurb describing Ambient"),
        ]
        let (hidden, byRep) = TaskDeduper.foldMap(tasks)
        #expect(byRep.count == 1)
        #expect(byRep["long"] != nil)                 // longest = representative
        #expect(Set(byRep["long"]!) == ["short", "long"])
        #expect(hidden == ["short"])
        #expect(!hidden.contains("other"))
    }

    @Test("an exact repeat across two calls folds")
    func foldsExactRepeat() {
        let tasks = [
            ("c1", "Deploy the K2.7 config after Dom's review"),
            ("c2", "Deploy the K2.7 config after Dom's review"),
        ]
        let (hidden, byRep) = TaskDeduper.foldMap(tasks)
        #expect(byRep.count == 1)
        #expect(hidden.count == 1)
    }

    @Test("SAFETY: tasks that merely share a few words are NEVER merged")
    func distinctTasksNeverMerge() {
        let tasks = [
            ("a", "Review the billing PR before the release"),   // shares review/pr/release with b…
            ("b", "Review the routing PR before the release"),   // …but billing≠routing — DIFFERENT tasks
            ("c", "Migrate the documentation from Notion to a version-controlled website"),
            ("d", "Merge the Notion docs into the GitHub docs and clean up outdated content"),
        ]
        let (hidden, byRep) = TaskDeduper.foldMap(tasks)
        #expect(byRep.isEmpty)     // none fold — token overlap can't safely call these the same
        #expect(hidden.isEmpty)
    }

    @Test("representative is the most-complete wording; every copy is a member for one-tap done")
    func representativeAndMembers() {
        let clusters = TaskDeduper.cluster([
            ("short", "Update pricing"),
            ("long", "Update pricing information in the new website design"),
        ])
        #expect(clusters.count == 1)
        #expect(clusters[0].representativeID == "long")
        #expect(Set(clusters[0].memberIDs) == ["short", "long"])
    }

    @Test("deterministic regardless of input order")
    func deterministic() {
        let a = [("t1", "Update pricing"), ("t2", "Update pricing information in the new website design"),
                 ("t3", "unrelated standalone task here")]
        let f1 = TaskDeduper.foldMap(a)
        let f2 = TaskDeduper.foldMap(a.reversed())
        #expect(f1.hidden == f2.hidden)
        #expect(f1.byRep == f2.byRep)
    }
}
