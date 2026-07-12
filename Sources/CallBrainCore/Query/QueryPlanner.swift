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
    case sourceFind       // "find where X said/asked that" — return the call moment, not synthesis
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
    public var addressedToUser: Bool
    public var exhaustive: Bool
    public init(mode: AskMode, dateRange: DateRange? = nil, speaker: String? = nil,
                addressedToUser: Bool = false, exhaustive: Bool = false) {
        self.mode = mode; self.dateRange = dateRange; self.speaker = speaker
        self.addressedToUser = addressedToUser
        self.exhaustive = exhaustive
    }
}

public enum QueryPlanner {
    public static func plan(_ query: String, now: Date = Date(), calendar: Calendar = .current) -> QueryPlan {
        let q = query.lowercased()
        let range = dateRange(in: q, now: now, calendar: calendar)
        // Person detection (Task 6.2 — `.person` was designed but unreachable: plan.speaker was
        // hard-coded nil). Action-items phrasing WINS the mode ("what did Jordan ask ME to do"
        // is a to-do question) but keeps the speaker as a retrieval boost. Unknown names degrade
        // to a harmless empty boost lane.
        let person = personCandidate(query)
        let mode = self.mode(for: q, hasDate: range != nil)
        let addressedToUser = self.addressedToUser(q)
        let exhaustive = self.exhaustiveScope(q)
        if mode == .actionItems || mode == .technical {
            return QueryPlan(mode: mode, dateRange: range, speaker: person,
                             addressedToUser: addressedToUser, exhaustive: exhaustive)
        }
        if mode == .sourceFind {
            return QueryPlan(mode: .sourceFind, dateRange: range, speaker: person,
                             addressedToUser: addressedToUser, exhaustive: exhaustive)
        }
        if let person {
            return QueryPlan(mode: .person, dateRange: range, speaker: person,
                             addressedToUser: addressedToUser, exhaustive: exhaustive)
        }
        return QueryPlan(mode: mode, dateRange: range, speaker: nil,
                         addressedToUser: addressedToUser, exhaustive: exhaustive)
    }

    /// "what did Riley say/ask/commit to…", "what has Jordan said about…" → "Riley"/"Jordan".
    /// The "what did X <verb>" frame is the signal — so we accept a LOWERCASE name too ("what did
    /// travis say", how people actually type) and guard against pronouns that fit the frame but
    /// aren't people (audit A HIGH: capitalization-only missed the common lowercase case).
    /// Words that fit the "what did X say" frame but are NOT a person — pronouns + articles/quantifiers.
    static let personStopwords: Set<String> = ["we", "you", "i", "they", "he", "she", "it", "everyone",
                                               "someone", "anyone", "that", "this", "the", "a", "an",
                                               "my", "our", "your", "their", "people", "who", "team"]
    static func personCandidate(_ raw: String) -> String? {
        let ns = raw as NSString
        let patterns = [
            #"\bwhat (?:did|has|does|is)\s+([A-Za-z][a-zA-Z]+(?:\s[A-Za-z][a-zA-Z]+)?)\s+(?:say|said|saying|ask|asked|asking|commit|committed|promise|promised|think|want|wanted|mention|mentioned|tell|told)"#,
            #"\bwhat\s+(?:was\s+)?(?:everything|all)\s+(?:did\s+)?([A-Za-z][a-zA-Z]+(?:\s[A-Za-z][a-zA-Z]+)?)\s+(?:say|said|mention|mentioned|ask|asked|commit|committed|tell|told)"#,
            #"\bwhat\s+all\s+did\s+([A-Za-z][a-zA-Z]+(?:\s[A-Za-z][a-zA-Z]+)?)\s+(?:say|said|mention|mentioned|ask|asked|commit|committed|tell|told)"#,
            #"^\s*([A-Za-z][a-zA-Z]+(?:\s[A-Za-z][a-zA-Z]+)??)\s+(?:(?:specifically|basically|actually|just|also|in\s+a\s+call|on\s+the\s+call)\s+)+(?:said|says|mentioned|asked|committed|promised|wanted|thinks|told)\b"#,
            #"^\s*([A-Za-z][a-zA-Z]+(?:\s[A-Za-z][a-zA-Z]+)?)\s+(?:said|says|mentioned|asked|committed|promised|wanted|thinks|told)\b"#,
            // Source-find phrasings that name the speaker mid-sentence ("find where Alex said…",
            // "which call did Alex mention…") — so a named speaker with no lines still refuses
            // rather than quoting someone else (Phase-2 audit HIGH).
            #"\b(?:where|which call|what call)\s+(?:did\s+)?([A-Za-z][a-zA-Z]+(?:\s[A-Za-z][a-zA-Z]+)?)\s+(?:say|said|saying|mention|mentioned|ask|asked|asking|bring|brought|commit|committed|promise|promised|tell|told|talk|talked|raise|raised|flag|flagged|want|wanted)"#,
        ]
        for pattern in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let m = re.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)) else { continue }
            if let name = cleanPersonCandidate(ns.substring(with: m.range(at: 1))) { return name }
        }
        return nil
    }

    private static func cleanPersonCandidate(_ raw: String) -> String? {
        let words = raw.split(separator: " ").map(String.init)
        // Reject if the FIRST word is a pronoun/article ("the team", "they") — not a name.
        guard let first = words.first?.lowercased(), !personStopwords.contains(first) else { return nil }
        // Title-case for a clean speaker label; downstream speaker matching is case-insensitive.
        return words.map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }.joined(separator: " ")
    }

    static func mode(for q: String, hasDate: Bool) -> AskMode {
        if sourceFindIntent(q) { return .sourceFind }
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

    static func sourceFindIntent(_ q: String) -> Bool {
        containsAny(q, ["find that", "find this", "find where", "show me where", "pull up where",
                        "where did", "what call", "which call", "exact moment", "specific moment",
                        "specific call", "source for", "quote where"])
    }

    static func addressedToUser(_ q: String) -> Bool {
        containsAny(q, ["ask me", "asked me", "tell me to", "told me to", "for me", "to me",
                        "my plate", "onto my plate", "my action", "my task", "i need to",
                        "i should", "you need to", "you should", "you have to"])
    }

    static func exhaustiveScope(_ q: String) -> Bool {
        containsAny(q, ["everything", "every thing", "what all", "across all calls",
                        "all calls", "all my calls", "every call", "from all calls",
                        "whole library", "whole archive"])
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
        // "past week" = the ROLLING last 7 days (Task 6.3 — the spec called out that a Tuesday
        // "past week" question must include Monday, not jump back to the previous calendar week).
        if q.contains("past week") {
            return range(add(startOfToday, days: -6), add(startOfToday, days: 1), "the past week")
        }
        // "last week" = the previous CALENDAR week.
        if q.contains("last week") {
            let s = weekStart(now, calendar)
            return range(add(s, days: -7), s, "last week")
        }
        // "past month" = a ROLLING ~30-day window ending today (parallels "past week"), so on Jul 4
        // it still includes Jul 1-4 — not the previous calendar month, which drops the newest calls
        // (audit A MED). "last month" stays the previous calendar month.
        if q.contains("past month") {
            return range(add(startOfToday, days: -29), add(startOfToday, days: 1), "the past month")
        }
        if q.contains("this month") {
            let s = monthStart(now, calendar)
            return range(s, add(s, months: 1), "this month")
        }
        if q.contains("last month") {
            let s = monthStart(now, calendar)
            return range(add(s, months: -1), s, "last month")
        }
        // Absolute dates (Task 6.3): "june 25", "jun 25th", "6/25". Year defaults to the current
        // one; a date >1 day in the future rolls back a year (people say "June 25" in July
        // meaning last month, not next year).
        if let abs = absoluteDate(in: q, now: now, calendar: calendar) {
            return range(abs, add(abs, days: 1), "\(ymd(abs))")
        }
        return nil
    }

    static let monthNames: [String: Int] = [
        "january": 1, "jan": 1, "february": 2, "feb": 2, "march": 3, "mar": 3, "april": 4, "apr": 4,
        "may": 5, "june": 6, "jun": 6, "july": 7, "jul": 7, "august": 8, "aug": 8,
        "september": 9, "sep": 9, "sept": 9, "october": 10, "oct": 10,
        "november": 11, "nov": 11, "december": 12, "dec": 12,
    ]

    static func absoluteDate(in q: String, now: Date, calendar: Calendar) -> Date? {
        var month: Int?; var day: Int?
        if let m = firstMatch(q, #"\b(jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)\s+(\d{1,2})(?:st|nd|rd|th)?\b"#) {
            month = monthNames[m.0]; day = Int(m.1)
        } else if let m = firstMatch(q, #"\b(\d{1,2})/(\d{1,2})\b"#) {
            month = Int(m.0); day = Int(m.1)
        }
        guard let month, let day, (1...12).contains(month), (1...31).contains(day) else { return nil }
        let year = calendar.component(.year, from: now)
        var comps = DateComponents(); comps.year = year; comps.month = month; comps.day = day
        guard let d = calendar.date(from: comps) else { return nil }
        // Future by more than a day → they meant last year's date.
        if d > calendar.date(byAdding: .day, value: 1, to: now)! {
            comps.year = year - 1
            return calendar.date(from: comps)
        }
        return d
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
