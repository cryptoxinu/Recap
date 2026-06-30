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
    public var id: String { a.id + "|" + b.id }
}

public enum DuplicateDetector {
    /// Suggest near-duplicate pairs. Both meetings must share a DATE; then a strong people-overlap or a
    /// strong title-overlap flags the pair. Conservative thresholds keep false positives low.
    public static func suggestions(_ meetings: [MeetingMeta], threshold: Double = 0.5) -> [DuplicateSuggestion] {
        var byDate: [String: [MeetingMeta]] = [:]
        for m in meetings { byDate[m.date, default: []].append(m) }

        var out: [DuplicateSuggestion] = []
        for (_, group) in byDate where group.count > 1 {
            for i in 0..<group.count {
                for j in (i + 1)..<group.count {
                    let a = group[i], b = group[j]
                    let people = jaccard(a.people, b.people)
                    let title = titleJaccard(a.title, b.title)
                    let score = max(people, title)
                    guard score >= threshold else { continue }
                    out.append(DuplicateSuggestion(a: a, b: b, score: score,
                                                   reason: reason(a, b, people: people, title: title)))
                }
            }
        }
        return out.sorted { $0.score > $1.score }
    }

    static func reason(_ a: MeetingMeta, _ b: MeetingMeta, people: Double, title: Double) -> String {
        if a.source != b.source && people >= 0.5 {
            return "Looks like the same call captured from \(label(a.source)) and \(label(b.source))."
        }
        if title >= 0.6 { return "Very similar titles on \(a.date)." }
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
