import Testing
@testable import CallBrainCore

/// Auto-complete-from-transcript detector (Tasks-overhaul Phase 3). The founder's HARD rule: never mark a
/// task done on ambiguous wording. These lock (a) clear completions → HIGH, (b) future/intent/negation →
/// NOTHING (the crux), (c) reworded/partial → AMBIGUOUS (review, not auto), (d) no cross-task bleed.
@Suite("TaskCompletionDetector — precision-first completion detection")
struct TaskCompletionDetectorTests {

    let tasks: [(id: String, text: String)] = [
        ("t_price", "Update the pricing page"),
        ("t_route", "Review the routing PR"),
        ("t_docs", "Update the onboarding docs"),
    ]

    private func detect(_ utterances: [String]) -> [TaskCompletionDetector.Match] {
        TaskCompletionDetector.detect(openTasks: tasks, utterances: utterances)
    }

    @Test("explicit past-tense completion that strict-matches a task → HIGH (safe to auto)")
    func highConfidence() {
        let m = detect(["Quick update — I finished the pricing page update earlier today."])
        #expect(m.count == 1)
        #expect(m.first?.taskID == "t_price")
        #expect(m.first?.confidence == .high)
    }

    @Test("FUTURE / intent is NOT completion (the crux — an 'update about' a task ≠ done)")
    func futureIntentExcluded() {
        #expect(detect(["I'll finish the pricing page update tomorrow."]).isEmpty)
        #expect(detect(["We still need to update the pricing page."]).isEmpty)
        #expect(detect(["Next step: update the pricing page."]).isEmpty)
        #expect(detect(["I'm going to update the pricing page this week."]).isEmpty)
    }

    @Test("NEGATION is NOT completion")
    func negationExcluded() {
        #expect(detect(["The pricing page update isn't done yet."]).isEmpty)
        #expect(detect(["I haven't finished the pricing page update."]).isEmpty)
        #expect(detect(["The pricing page update is not complete."]).isEmpty)
    }

    @Test("reworded / partial completion → AMBIGUOUS (review, never auto)")
    func ambiguousTier() {
        let m = detect(["Good news, the onboarding docs are done."])
        #expect(m.count == 1)
        #expect(m.first?.taskID == "t_docs")
        #expect(m.first?.confidence == .ambiguous)   // "onboarding docs" ⊂ task but ≠3 tokens / not ≥0.9
    }

    @Test("a completion about a DIFFERENT task never bleeds (billing ≠ routing)")
    func noCrossTaskBleed() {
        #expect(detect(["I finished the billing PR."]).isEmpty)   // shares only 'pr' with 'Review the routing PR'
    }

    @Test("praise / non-task completions don't complete anything")
    func noFalsePositive() {
        #expect(detect(["Great work everyone, well done, that was a solid call."]).isEmpty)
    }

    @Test("de-duped per task (highest tier wins), order-independent decisions")
    func dedupedAndStable() {
        let utt = ["I finished the pricing page update.", "Yeah the pricing page update is done."]
        let a = detect(utt), b = detect(utt.reversed())
        // The DECISIONS (which task, what tier) are order-independent; the evidence display string follows
        // transcript order, which is fine.
        func decisions(_ m: [TaskCompletionDetector.Match]) -> Set<String> { Set(m.map { "\($0.taskID):\($0.confidence.rawValue)" }) }
        #expect(decisions(a) == decisions(b))
        #expect(a.filter { $0.taskID == "t_price" }.count == 1)   // one row per task, not two
        #expect(a.first { $0.taskID == "t_price" }?.confidence == .high)
    }

    @Test("empty inputs are safe")
    func emptyInputs() {
        #expect(TaskCompletionDetector.detect(openTasks: [], utterances: ["I finished everything."]).isEmpty)
        #expect(detect([]).isEmpty)
    }
}
