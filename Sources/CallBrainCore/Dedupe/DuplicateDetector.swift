import Foundation

/// Lightweight metadata for near-duplicate scanning (Phase 6).
public struct MeetingMeta: Sendable, Equatable {
    public let id: String
    public let title: String
    public let date: String
    public let source: String
    public let people: Set<String>     // lowercased person names (NER / participants)
    public init(id: String, title: String, date: String, source: String, people: Set<String>) {
        self.id = id; self.title = title; self.date = date; self.source = source; self.people = people
    }
}

/// A *suggested* near-duplicate pair — heuristic, never auto-merged. The user confirms (delete one) or
/// dismisses. The most common real case: the SAME call captured twice (Gemini notes + a Fireflies
/// transcript) — same date, overlapping people, different source — which the exact content-hash dedupe
/// (different text) can't catch.
public struct DuplicateSuggestion: Sendable, Equatable, Identifiable {
    public let a: MeetingMeta
    public let b: MeetingMeta
    public let score: Double
    public let reason: String
    /// Order-independent (Codex P6 gate LOW): a dismissal of A|B must not re-appear as B|A after a
    /// non-deterministic same-date re-ordering.
    public var id: String { [a.id, b.id].sorted().joined(separator: "|") }
}

public enum DuplicateDetector {
    /// Generic auto-titles carry no identity → never match two meetings on title alone.
    static let genericTitles: Set<String> = ["untitled meeting", "imported call", "recorded meeting", "recorded call"]

    /// Suggest near-duplicate pairs. Both meetings share a DATE; then we need a *strong* signal — a real
    /// people overlap (≥2 shared, high Jaccard) OR a strong non-generic title match. A single shared 1:1
    /// person, or two same-day "Untitled" imports, are NOT flagged (Codex P6 gate MED — false positives
    /// paired with an irreversible delete are unsafe).
    public static func suggestions(_ meetings: [MeetingMeta]) -> [DuplicateSuggestion] {
        var byDate: [String: [MeetingMeta]] = [:]
        for m in meetings { byDate[m.date, default: []].append(m) }

        var out: [DuplicateSuggestion] = []
        for (_, group) in byDate where group.count > 1 {
            for i in 0..<group.count {
                for j in (i + 1)..<group.count {
                    let a = group[i], b = group[j]
                    let shared = a.people.intersection(b.people).count
                    let people = jaccard(a.people, b.people)
                    let title = genericPair(a.title, b.title) ? 0 : titleJaccard(a.title, b.title)

                    let strongPeople = shared >= 2 && people >= 0.6
                    let crossSourceSameCall = a.source != b.source && shared >= 2 && people >= 0.5
                    let strongTitle = title >= 0.6
                    guard strongPeople || crossSourceSameCall || strongTitle else { continue }

                    let score = max(people, title)
                    out.append(DuplicateSuggestion(a: a, b: b, score: score,
                        reason: reason(a, b, crossSource: crossSourceSameCall, strongTitle: strongTitle)))
                }
            }
        }
        return out.sorted { $0.score > $1.score }
    }

    private static func genericPair(_ a: String, _ b: String) -> Bool {
        genericTitles.contains(a.lowercased().trimmingCharacters(in: .whitespaces))
            || genericTitles.contains(b.lowercased().trimmingCharacters(in: .whitespaces))
    }

    static func reason(_ a: MeetingMeta, _ b: MeetingMeta, crossSource: Bool, strongTitle: Bool) -> String {
        if crossSource { return "Looks like the same call captured from \(label(a.source)) and \(label(b.source))." }
        if strongTitle { return "Very similar titles on \(a.date)." }
        return "Same day, mostly the same people."
    }

    public static func jaccard<T: Hashable>(_ a: Set<T>, _ b: Set<T>) -> Double {
        guard !a.isEmpty || !b.isEmpty else { return 0 }
        let inter = a.intersection(b).count
        let union = a.union(b).count
        return union == 0 ? 0 : Double(inter) / Double(union)
    }

    static func titleJaccard(_ a: String, _ b: String) -> Double {
        jaccard(tokens(a), tokens(b))
    }
    private static func tokens(_ s: String) -> Set<String> {
        Set(s.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init).filter { $0.count > 2 })
    }
    private static func label(_ source: String) -> String {
        switch source {
        case "gmeet_gemini": "Google Meet notes"
        case "gmeet_local", "gmeet_cloud": "a recording"
        case "fireflies": "Fireflies"; case "fathom": "Fathom"; case "cluely": "Cluely"
        case "paste": "pasted text"; default: source
        }
    }
}
