import Foundation

/// Lifts action items out of a meeting (Phase 4). The deterministic path handles Gemini "Notes by
/// Gemini" — which already encodes tasks as `[Owner] text` lines and bullets under an "Action items" /
/// "Next steps" section — so the founder's real data yields a tasks list with **no LLM cost**. Transcript
/// extraction (LLM-grounded) layers on top of this same shape later.
public enum ActionItemExtractor {
    public struct Extracted: Sendable, Equatable {
        public let owner: String?
        public let text: String
        public init(owner: String?, text: String) { self.owner = owner; self.text = text }
    }

    private static let sectionSignals = ["action item", "next step", "action point", "to do", "to-do",
                                         "todo", "follow up", "follow-up", "owed", "tasks"]

    /// Deterministic extraction from note lines (each utterance = one line). `[Owner] …` lines are tasks
    /// anywhere; plain bullets are tasks only inside an action-items / next-steps section.
    public static func fromNotes(_ utterances: [ParsedUtterance]) -> [Extracted] {
        var out: [Extracted] = []
        var seen = Set<String>()
        var inActionSection = false

        func add(_ e: Extracted) {
            let key = "\(e.owner?.lowercased() ?? "")|\(e.text.lowercased())"
            if seen.insert(key).inserted { out.append(e) }
        }

        for u in utterances {
            let raw = u.text.trimmingCharacters(in: .whitespaces)
            if raw.isEmpty { continue }
            if raw.hasPrefix("## ") {
                let title = String(raw.dropFirst(3)).lowercased()
                inActionSection = sectionSignals.contains { title.contains($0) }
                continue
            }
            // Strip a leading bullet glyph BEFORE owner detection, so `• [Jordan] …` still attributes
            // to Jordan instead of becoming an unassigned `[Jordan] …` line (Codex P4 gate MED).
            var line = raw
            for glyph in ["•", "◦", "-", "*"] where line.hasPrefix(glyph) {
                line = String(line.dropFirst(glyph.count)).trimmingCharacters(in: .whitespaces); break
            }
            if isNegative(line) { continue }                 // "No action items were identified." etc.
            if let owned = ownerLine(line) {
                if !isNoiseNote(owned.text) { add(Extracted(owner: owned.owner, text: owned.text)) }
            } else if inActionSection, line.count >= 3, !isNoiseNote(line) {
                add(Extracted(owner: nil, text: line))
            }
        }
        return out
    }

    /// "No action items / none / N/A / nothing to do" placeholders are not tasks. Kept narrow so a real
    /// task ("Notify Riley…", "No longer pursue Meow — confirm with Alex") isn't filtered.
    static func isNegative(_ s: String) -> Bool {
        let t = s.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " .!"))
        if t == "none" || t == "n/a" || t == "na" || t == "nothing" { return true }
        return (t.contains("no action") || t.contains("none identified")
                || t.contains("nothing to") || t.contains("no follow-up") || t.contains("no follow up")
                || t.contains("no tasks")) && t.count < 60
    }

    /// A note line that isn't a real task — a bare date ("Jul 10, 2026"), a stray number/amount ("$5M"),
    /// or a fragment with fewer than two real words. Kept light: Gemini already curates these notes, so we
    /// only strip the obvious non-tasks that inflate the list and read as noise (founder: "is that even a
    /// task?"). A real task always carries ≥2 alphabetic words ("Update pricing information").
    static func isNoiseNote(_ text: String) -> Bool {
        let alphaWords = text.split(whereSeparator: { !$0.isLetter }).filter { $0.count >= 2 }
        return alphaWords.count < 2
    }

    /// `[Owner] the task text` → (owner, text). The owner is a single short name OR a comma-separated
    /// list of names ("[Jordan Reyes, Sam Okafor, Alex] …"). Public + reused by the one-time
    /// repair of already-stored tasks whose owner list was left inside the text.
    public static func ownerLine(_ s: String) -> (owner: String, text: String)? {
        guard s.hasPrefix("["), let close = s.firstIndex(of: "]") else { return nil }
        let owner = String(s[s.index(after: s.startIndex)..<close]).trimmingCharacters(in: .whitespaces)
        let text = String(s[s.index(after: close)...]).trimmingCharacters(in: CharacterSet(charactersIn: " :-")).trimmingCharacters(in: .whitespaces)
        guard !owner.isEmpty, text.count >= 3, isPlausibleOwner(owner) else { return nil }
        return (owner, text)
    }

    /// A `[…]` prefix is an owner when it's one short name, OR a comma-separated list of short name-like
    /// parts. The list case previously fell through the old `count <= 40` cap, so a 3-person owner
    /// ("[Jordan Reyes, Sam Okafor, Alex]") was left un-parsed — the whole `[names] text`
    /// became an UNASSIGNED task with the names stuck in the text (founder bug 2026-07-09). We still reject
    /// a bracketed sentence / URL / timestamp so a `[note]` block isn't misread as an owner.
    static func isPlausibleOwner(_ owner: String) -> Bool {
        // Single owner: keep the historical short cap.
        if owner.count <= 40, !owner.contains("/"), !owner.contains("http") { return true }
        // Longer: only a genuine comma-separated NAME LIST qualifies.
        let parts = owner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2, parts.count <= 6 else { return false }
        return parts.allSatisfy { p in
            !p.isEmpty && p.count <= 30
                && p.allSatisfy { $0.isLetter || $0 == " " || $0 == "." || $0 == "-" || $0 == "'" }
        }
    }
}
