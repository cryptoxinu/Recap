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
            let line = u.text.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("## ") {
                let title = String(line.dropFirst(3)).lowercased()
                inActionSection = sectionSignals.contains { title.contains($0) }
                continue
            }
            if let owned = ownerLine(line) {
                add(Extracted(owner: owned.owner, text: owned.text))
            } else if inActionSection {
                let clean = line.hasPrefix("•") ? String(line.dropFirst()).trimmingCharacters(in: .whitespaces) : line
                if clean.count >= 3 { add(Extracted(owner: nil, text: clean)) }
            }
        }
        return out
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
