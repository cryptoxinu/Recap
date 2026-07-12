import Testing
import Foundation
@testable import CallBrainCore

/// Perfection plan Task 2.4 — after a 2.3 merge, one call carries BOTH halves' extracted tasks:
/// the notes-half and transcript-half word the SAME to-do slightly differently, so dedupe_key
/// equality misses them. This pass drops open near-duplicates per (owner, meeting).
@Suite("Cross-half task dedupe")
struct TaskCrossHalfDedupeTests {

    private func item(_ id: String, _ owner: String?, _ text: String,
                      status: ActionItem.Status = .open, at: Double = 0) -> ActionItem {
        ActionItem(id: id, meetingID: "m1", owner: owner, text: text, status: status, createdAt: at)
    }

    @Test("same owner, reworded same task → later one dropped")
    func testNearDupDropped() {
        let plan = TaskIntelligence.crossHalfDedupePlan([
            item("a", "Alex", "Fix the BitRouter reasoning format", at: 1),
            item("b", "Alex", "Fix BitRouter's reasoning output format issue", at: 2),
        ])
        #expect(plan == ["b"])
    }

    @Test("same text, different owners → both kept")
    func testDifferentOwnersKept() {
        let plan = TaskIntelligence.crossHalfDedupePlan([
            item("a", "Alex", "Review the subscription PR", at: 1),
            item("b", "Chris", "Review the subscription PR", at: 2),
        ])
        #expect(plan.isEmpty)
    }

    @Test("a DONE task is never dropped; its open duplicate is")
    func testDoneWinsOverOpenDuplicate() {
        let plan = TaskIntelligence.crossHalfDedupePlan([
            item("a", "Alex", "Send Junney the Ambient blurb", status: .open, at: 1),
            item("b", "Alex", "Send Junney a blurb about Ambient", status: .done, at: 2),
        ])
        #expect(plan == ["a"])   // the done record survives even though it's newer
    }

    @Test("unrelated tasks under one owner are untouched")
    func testUnrelatedKept() {
        let plan = TaskIntelligence.crossHalfDedupePlan([
            item("a", "Alex", "Fix the BitRouter reasoning format", at: 1),
            item("b", "Alex", "Email the pitch deck to Riley", at: 2),
        ])
        #expect(plan.isEmpty)
    }

    @Test("similar-but-different tasks survive strict mode (Codex phase-2 MED)")
    func testSimilarButDifferentKept() {
        // 2 shared tokens at 0.67 overlap — Tidy's loose rule would collide these; deletion must not.
        let plan = TaskIntelligence.crossHalfDedupePlan([
            item("a", "Chris", "Review the billing PR", at: 1),
            item("b", "Chris", "Review the routing PR", at: 2),
        ])
        #expect(plan.isEmpty)
        // Tidy's re-add guard keeps its original recall (non-strict).
        #expect(TaskIntelligence.isNearDuplicate("Review the billing PR", of: ["Review the routing PR"]))
    }
}
