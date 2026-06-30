import Foundation

/// Hard date window for a question, expressed as **YYYY-MM-DD strings** matching the `meetings.date`
/// column (so filtering is a pure string compare — no epoch/timezone drift). `endYMDExclusive` is the
/// day AFTER the last included day. Computed in the local calendar.
public struct DateRange: Sendable, Equatable {
    public let startYMD: String          // inclusive
    public let endYMDExclusive: String   // exclusive
    public let label: String             // human phrase, e.g. "this week" (for UI + the reasoning trace)
    public init(startYMD: String, endYMDExclusive: String, label: String) {
        self.startYMD = startYMD; self.endYMDExclusive = endYMDExclusive; self.label = label
    }
}

/// The ask "mode" — how the question should be answered (Phase 4). General/person are live in Phase 1;
/// the others tune retrieval + the answer template.
public enum AskMode: String, Sendable, Equatable, CaseIterable {
    case general          // open question across the whole corpus
    case person           // "what did <name> say…"
    case timeScoped       // "this week / yesterday / last month…" (hard date window)
    case actionItems      // "what do I owe / what did <name> ask me to do"
    case technical        // "explain how X works" (prefers explanatory chunks)
}

/// A deterministic plan derived from the raw question: a hard date window, an optional speaker filter,
/// and the answer mode. The planner is pure + offline + testable; an LLM fallback is layered on later
/// for the cases the deterministic pass can't classify. This is the spine of hard date-gating (a
/// time-scoped question must NOT pull evidence from outside its window) and the Phase-4.5 reasoning trace.
public struct QueryPlan: Sendable, Equatable {
    public var mode: AskMode
    public var dateRange: DateRange?
    public var speaker: String?
    public init(mode: AskMode, dateRange: DateRange? = nil, speaker: String? = nil) {
        self.mode = mode; self.dateRange = dateRange; self.speaker = speaker
    }
}

public enum QueryPlanner {
    public static func plan(_ query: String, now: Date = Date(), calendar: Calendar = .current) -> QueryPlan {
        let q = query.lowercased()
        let range = dateRange(in: q, now: now, calendar: calendar)
        let mode = self.mode(for: q, hasDate: range != nil)
        return QueryPlan(mode: mode, dateRange: range, speaker: nil)
    }

    static func mode(for q: String, hasDate: Bool) -> AskMode {
        if containsAny(q, ["action item", "to do", "to-do", "todo", "owe", "owed", "ask me to",
                           "asked me to", "follow up", "follow-up", "my tasks", "action items"]) {
            return .actionItems
        }
        if containsAny(q, ["how does", "how do", "explain", "what is", "what's the difference",
                           "how to", "walk me through", "deep dive"]) {
            return .technical
        }
        if hasDate { return .timeScoped }
        return .general
    }

    // MARK: - date parsing (local calendar; returns YMD strings)

    static func dateRange(in q: String, now: Date, calendar: Calendar) -> DateRange? {
        func ymd(_ d: Date) -> String { TimeCode.ymd(d, calendar: calendar) }
        let startOfToday = calendar.startOfDay(for: now)

        func range(_ start: Date, _ endExclusive: Date, _ label: String) -> DateRange {
            DateRange(startYMD: ymd(start), endYMDExclusive: ymd(endExclusive), label: label)
        }
        func add(_ d: Date, days: Int) -> Date { calendar.date(byAdding: .day, value: days, to: d)! }
        func add(_ d: Date, months: Int) -> Date { calendar.date(byAdding: .month, value: months, to: d)! }

        // "last/past N days|weeks|months" (rolling window ending today). firstMatch returns
        // (group1, group2) as (.0, .1): .0 = the number, .1 = the unit.
        if let m = firstMatch(q, #"(?:last|past)\s+(\d{1,3})\s+(day|days|week|weeks|month|months)"#) {
            let n = max(1, Int(m.0) ?? 1)
            let unit = m.1
            let start: Date
            if unit.hasPrefix("day") { start = add(startOfToday, days: -(n - 1)) }
            else if unit.hasPrefix("week") { start = add(startOfToday, days: -(7 * n - 1)) }
            else { start = add(startOfToday, months: -n) }
            let unitLabel = unit.hasPrefix("day") ? "days" : unit.hasPrefix("week") ? "weeks" : "months"
            return range(start, add(startOfToday, days: 1), "the last \(n) \(unitLabel)")
        }

        if containsWord(q, "today") {
            return range(startOfToday, add(startOfToday, days: 1), "today")
        }
        if containsWord(q, "yesterday") {
            return range(add(startOfToday, days: -1), startOfToday, "yesterday")
        }
        if q.contains("this week") {
            let s = weekStart(now, calendar)
            return range(s, add(s, days: 7), "this week")
        }
        if q.contains("last week") {
            let s = weekStart(now, calendar)
            return range(add(s, days: -7), s, "last week")
        }
        if q.contains("this month") {
            let s = monthStart(now, calendar)
            return range(s, add(s, months: 1), "this month")
        }
        if q.contains("last month") {
            let s = monthStart(now, calendar)
            return range(add(s, months: -1), s, "last month")
        }
        return nil
    }

    /// Start of the week containing `d`, honoring the calendar's `firstWeekday`.
    static func weekStart(_ d: Date, _ calendar: Calendar) -> Date {
        calendar.dateInterval(of: .weekOfYear, for: d)?.start ?? calendar.startOfDay(for: d)
    }
    static func monthStart(_ d: Date, _ calendar: Calendar) -> Date {
        calendar.dateInterval(of: .month, for: d)?.start ?? calendar.startOfDay(for: d)
    }

    // MARK: - helpers

    static func containsAny(_ s: String, _ needles: [String]) -> Bool { needles.contains { s.contains($0) } }

    /// Whole-word contains (so "today" doesn't match inside "todayish" and "owe" not inside "power").
    static func containsWord(_ s: String, _ word: String) -> Bool {
        firstMatch(s, "\\b\(NSRegularExpression.escapedPattern(for: word))\\b") != nil
    }

    static func firstMatch(_ s: String, _ pattern: String) -> (String, String)? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let g1 = m.numberOfRanges > 1 && m.range(at: 1).location != NSNotFound ? ns.substring(with: m.range(at: 1)) : ""
        let g2 = m.numberOfRanges > 2 && m.range(at: 2).location != NSNotFound ? ns.substring(with: m.range(at: 2)) : ""
        return (g1, g2)
    }
}
