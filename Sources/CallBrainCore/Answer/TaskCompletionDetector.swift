import Foundation

/// Detects which existing OPEN tasks a call's transcript says are DONE — deterministically, no AI, so it
/// works even with Local AI off (Tasks-overhaul Phase 3). Precision-first by design (founder's hard rule:
/// NEVER mark a task done on an ambiguous "update"): a match needs a **past/perfect completion verb** with
/// NO future/intent/negation, tied to a task by the same strict token-overlap the deletion path uses.
///
/// Two tiers, so the caller can be safe:
/// - `.high`  — completion statement STRICT-matches one open task → safe to auto-complete.
/// - `.ambiguous` — a looser match → route to a review banner / the LLM, NEVER auto-complete.
///
/// Recall is deliberately modest (exact tokens, no stemming): "the docs migration is done" won't match a
/// task worded "Migrate the documentation from Notion". That's fine — the LLM paths (Tidy / "Have AI
/// review") catch the reworded cases; this catches only the slam-dunks. Missing a few beats mis-completing.
public enum TaskCompletionDetector {

    public enum Confidence: String, Sendable, Equatable { case high, ambiguous }

    public struct Match: Sendable, Equatable {
        public let taskID: String
        public let confidence: Confidence
        public let evidence: String   // the completion sentence, for the "✓ from ‹call›" / review UI
        public init(taskID: String, confidence: Confidence, evidence: String) {
            self.taskID = taskID; self.confidence = confidence; self.evidence = evidence
        }
    }

    /// Detect open tasks the utterances report as done. Deterministic + order-independent.
    public static func detect(openTasks: [(id: String, text: String)], utterances: [String]) -> [Match] {
        guard !openTasks.isEmpty else { return [] }
        var best: [String: Match] = [:]
        for u in utterances {
            for s in sentences(u) where isCompletionStatement(s) {
                for t in openTasks {
                    // Match the TASK against the completion sentence (task tokens ⊆ sentence ⇒ high overlap).
                    let conf: Confidence
                    if TaskIntelligence.isNearDuplicate(t.text, of: [s], strict: true) { conf = .high }
                    else if TaskIntelligence.isNearDuplicate(t.text, of: [s], strict: false) { conf = .ambiguous }
                    else { continue }
                    // Keep the strongest tier per task; a .high already found is never downgraded.
                    if best[t.id]?.confidence == .high { continue }
                    if best[t.id] == nil || conf == .high {
                        best[t.id] = Match(taskID: t.id, confidence: conf, evidence: String(s.prefix(160)))
                    }
                }
            }
        }
        return best.values.sorted { $0.taskID < $1.taskID }   // deterministic ordering
    }

    // MARK: - completion-statement gate

    /// A sentence asserts a task is DONE: carries a past/perfect completion signal AND no future / intent /
    /// negation. The disqualifiers are the crux — an "update about" a task ("I'll finish X", "still need to
    /// do X", "X isn't done yet") must NOT read as completion.
    static func isCompletionStatement(_ s: String) -> Bool {
        let l = " " + s.lowercased() + " "
        let disqualifiers = [
            "will ", "'ll ", "won't", "need to", "needs to", "have to", "has to", "going to", "gonna ",
            "should ", "let's", "let me", "plan to", "planning to", "want to", "trying to", "would ",
            "could ", "might ", "to do ", "to-do", "next step", "action item",
            // negations of completion
            "not done", "not finished", "not complete", "isn't done", "aren't done", "n't done",
            "n't finished", "haven't", "hasn't", "didn't", "did not", "not yet", "still need",
            "still working", "wasn't able", "couldn't ", "can't ",
        ]
        if disqualifiers.contains(where: l.contains) { return false }
        let signals = [
            "finished ", " is done", " are done", " is complete", "completed ", "shipped ", "wrapped up",
            "took care of", "taken care of", " is handled", "handled ", "already sent", "already did",
            "already done", "got it done", "got that done", " is merged", "merged ", " is deployed",
            "deployed ", " is closed", "closed out", " done.", " done,", " done ", "sent out", "sorted out",
            " is sorted", " went live", " is live",
        ]
        return signals.contains(where: l.contains)
    }

    /// Split an utterance into sentence-ish spans (completion claims are per-sentence).
    static func sentences(_ s: String) -> [String] {
        s.split(whereSeparator: { $0 == "." || $0 == "!" || $0 == "?" || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count >= 4 }
    }
}
