import Foundation

/// Lightweight metadata for near-duplicate scanning (Phase 6).
public struct MeetingMeta: Sendable, Equatable {
    public let id: String
    public let title: String            // the ORIGINAL title (often a date-time stamp for auto-named calls)
    public let smartTitle: String?      // the AI-detected meaningful name, when present
    public let date: String
    public let source: String
    public let people: Set<String>      // lowercased person names (NER / participants)
    public init(id: String, title: String, smartTitle: String? = nil, date: String, source: String, people: Set<String>) {
        self.id = id; self.title = title; self.smartTitle = smartTitle
        self.date = date; self.source = source; self.people = people
    }
    /// The meaningful name to match + display on — the AI title when we have one, else the raw title.
    public var displayTitle: String { (smartTitle?.isEmpty == false) ? smartTitle! : title }
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

    /// Suggest near-duplicate pairs. The ONLY signals strong enough to pair (since the action is an
    /// irreversible delete) are:
    ///  • cross-source + same day + real people overlap — the same call captured by two tools; OR
    ///  • a strong, NON-generic *meaningful-title* match (uses the AI title, not the date-time stamp).
    /// Crucially, two DIFFERENT same-source calls on the same day with the same recurring team (e.g. two
    /// Ambient standups) are NOT flagged — shared attendees alone is not duplication (founder bug
    /// 2026-06-30: two different-time calls flagged "100% match" on their "Meeting started <date>" titles).
    public static func suggestions(_ meetings: [MeetingMeta]) -> [DuplicateSuggestion] {
        var byDate: [String: [MeetingMeta]] = [:]
        for m in meetings { byDate[m.date, default: []].append(m) }

        var out: [DuplicateSuggestion] = []
        for (_, group) in byDate where group.count > 1 {
            for i in 0..<group.count {
                for j in (i + 1)..<group.count {
                    let a = group[i], b = group[j]
                    let shared = a.people.intersection(b.people).count
                    // First-name-normalized overlap too, so the SAME call recorded by two tools that format
                    // names differently ("Alex Kim" vs "Alex") still matches across sources.
                    let aFirst = firstNames(a.people), bFirst = firstNames(b.people)
                    let sharedFirst = aFirst.intersection(bFirst).count
                    let peopleFirst = jaccard(aFirst, bFirst), people = jaccard(a.people, b.people)
                    // Match on the MEANINGFUL title (AI title), never the date-time stamp — and only when
                    // both titles are non-generic.
                    let title = genericPair(a.displayTitle, b.displayTitle) ? 0 : titleJaccard(a.displayTitle, b.displayTitle)

                    // Cross-source + same-day is itself a strong signal (two tools rarely record the same
                    // day + people unless it's the same call).
                    let crossSourceSameCall = a.source != b.source
                        && max(shared, sharedFirst) >= 2 && max(people, peopleFirst) >= 0.4
                    let strongTitle = title >= 0.6
                    guard crossSourceSameCall || strongTitle else { continue }

                    let score = max(crossSourceSameCall ? max(people, peopleFirst) : 0, title)
                    out.append(DuplicateSuggestion(a: a, b: b, score: score,
                        reason: reason(a, b, crossSource: crossSourceSameCall, strongTitle: strongTitle)))
                }
            }
        }
        return out.sorted { $0.score > $1.score }
    }

    /// A title with no identity for matching: the small fixed set, or an auto-generated date/time stamp
    /// title ("Meeting started 2026-06-24 12-32 PDT", "Meeting on 2026-06-24", a bare date).
    static func isGenericTitle(_ s: String) -> Bool {
        let t = s.lowercased().trimmingCharacters(in: .whitespaces)
        if t.isEmpty || genericTitles.contains(t) { return true }
        if t.hasPrefix("meeting started") || t.hasPrefix("meeting on") || t.hasPrefix("new meeting") { return true }
        // Generic ONLY when the title is essentially just a date/time stamp — strip dates, times, and
        // timezone/filler words, and if almost no real letters remain it carried no subject. A real title
        // that merely contains a date ("Q3 Board Review 2026-06-24") keeps its letters → not generic.
        let stripped = t
            .replacingOccurrences(of: #"\d{1,4}[-/.:]\d{1,2}([-/.:]\d{1,4})?"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\b(am|pm|pdt|pst|est|edt|cst|cdt|mst|mdt|gmt|utc|at|on)\b"#, with: " ", options: .regularExpression)
        return stripped.filter(\.isLetter).count < 3
    }

    private static func genericPair(_ a: String, _ b: String) -> Bool {
        isGenericTitle(a) || isGenericTitle(b)
    }

    static func reason(_ a: MeetingMeta, _ b: MeetingMeta, crossSource: Bool, strongTitle: Bool) -> String {
        if crossSource { return "Looks like the same call captured from \(label(a.source)) and \(label(b.source))." }
        if strongTitle { return "Very similar titles on \(a.date)." }
        return "Same day, mostly the same people."
    }

    /// First token of each name (lowercased) — so "Alex Kim" and "Alex" normalize to the same person when
    /// two recording tools format names differently.
    static func firstNames(_ people: Set<String>) -> Set<String> {
        Set(people.compactMap { $0.split(separator: " ").first.map { String($0).lowercased() } })
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
        case "gmeet_captions": "Google Meet captions"
        case "gmeet_local", "gmeet_cloud": "a recording"
        case "fireflies": "Fireflies"; case "fathom": "Fathom"; case "cluely": "Cluely"
        case "paste": "pasted text"; default: source
        }
    }
}
