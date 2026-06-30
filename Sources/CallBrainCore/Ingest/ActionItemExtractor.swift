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
            // Strip a leading bullet glyph BEFORE owner detection, so `• [Ghazal] …` still attributes
            // to Ghazal instead of becoming an unassigned `[Ghazal] …` line (Codex P4 gate MED).
            var line = raw
            for glyph in ["•", "◦", "-", "*"] where line.hasPrefix(glyph) {
                line = String(line.dropFirst(glyph.count)).trimmingCharacters(in: .whitespaces); break
            }
            if isNegative(line) { continue }                 // "No action items were identified." etc.
            if let owned = ownerLine(line) {
                add(Extracted(owner: owned.owner, text: owned.text))
            } else if inActionSection, line.count >= 3 {
                add(Extracted(owner: nil, text: line))
            }
        }
        return out
    }

    /// "No action items / none / N/A / nothing to do" placeholders are not tasks. Kept narrow so a real
    /// task ("Notify Travis…", "No longer pursue Meow — confirm with Max") isn't filtered.
    static func isNegative(_ s: String) -> Bool {
        let t = s.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " .!"))
        if t == "none" || t == "n/a" || t == "na" || t == "nothing" { return true }
        return (t.contains("no action") || t.contains("none identified")
                || t.contains("nothing to") || t.contains("no follow-up") || t.contains("no follow up")
                || t.contains("no tasks")) && t.count < 60
    }

    /// `[Owner] the task text` → (owner, text). Owner must be short and non-empty.
    static func ownerLine(_ s: String) -> (owner: String, text: String)? {
        guard s.hasPrefix("["), let close = s.firstIndex(of: "]") else { return nil }
        let owner = String(s[s.index(after: s.startIndex)..<close]).trimmingCharacters(in: .whitespaces)
        let text = String(s[s.index(after: close)...]).trimmingCharacters(in: CharacterSet(charactersIn: " :-")).trimmingCharacters(in: .whitespaces)
        guard !owner.isEmpty, owner.count <= 40, text.count >= 3 else { return nil }
        return (owner, text)
    }
}
