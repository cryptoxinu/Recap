import Foundation

/// Calendar v4 — natural-language quick-add. Parses "lunch w/ Sam Fri 1pm",
/// "sync tomorrow 3-3:30", "standup at 9am Monday" into an EventDraft. Deterministic and
/// timezone-explicit so it's fully testable; the app confirms the draft in the editor before
/// writing, so a wrong guess is never silently saved.
public enum EventDraftParser {

    /// Returns nil when no time can be found (the caller keeps the field open rather than
    /// inventing a time). `now` and `calendar` are injected for tests.
    public static func parse(_ raw: String, now: Date = Date(),
                             calendar: Calendar = .current) -> EventDraft? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // 1. Attendees: "with Sam", "w/ Sam and Alex". Pull them, remove from the title text.
        var attendees: [String] = []
        if let r = text.range(of: #"\b(?:with|w/)\s+(.+?)(?=\s+(?:on|at|tomorrow|today|next|mon|tue|wed|thu|fri|sat|sun|\d)|$)"#,
                              options: [.regularExpression, .caseInsensitive]) {
            let names = String(text[r]).replacingOccurrences(of: "with", with: "", options: .caseInsensitive)
                .replacingOccurrences(of: "w/", with: "")
            attendees = names.components(separatedBy: CharacterSet(charactersIn: ",&"))
                .flatMap { $0.components(separatedBy: " and ") }
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            text.removeSubrange(r)
        }

        // 2. Location.
        var location: String? = nil
        // 2a. Conferencing keywords — NOT bare "meet" (audit HIGH: "meet with Sam" would lose
        // the verb and empty the title); only unambiguous tokens / "google meet".
        for kw in ["zoom", "google meet", "gmeet", "teams", "webex", "hangout", "phone call"] {
            if let r = text.range(of: "\\b\(kw)\\b", options: [.regularExpression, .caseInsensitive]) {
                location = String(text[r]); text.removeSubrange(r); break
            }
        }
        // 2b. "at <place>" — only when NOT followed by a digit (that's a time: "at 1pm").
        //     Bounded to the phrase before the next day/time keyword (audit MED).
        if location == nil,
           let r = text.range(of: #"\bat\s+(?![0-9])([\p{L}][\p{L}0-9'&. ]*?)(?=\s+(?:on|tomorrow|today|next|mon|tue|wed|thu|fri|sat|sun|\d{1,2}(?::\d{2})?\s*(?:am|pm))|$)"#,
                              options: [.regularExpression, .caseInsensitive]) {
            var loc = String(text[r])
            loc = loc.replacingOccurrences(of: #"^at\s+"#, with: "", options: [.regularExpression, .caseInsensitive])
                .trimmingCharacters(in: .whitespaces)
            if !loc.isEmpty { location = loc; text.removeSubrange(r) }
        }

        // 3. Day: today / tomorrow / weekday name / "next <weekday>". Default = today.
        let lower = text.lowercased()
        var day = calendar.startOfDay(for: now)
        var dayMatched = false
        if lower.contains("tomorrow") {
            day = calendar.date(byAdding: .day, value: 1, to: day) ?? day; dayMatched = true
            text = text.replacingOccurrences(of: "tomorrow", with: "", options: .caseInsensitive)
        } else if lower.contains("today") {
            dayMatched = true
            text = text.replacingOccurrences(of: "today", with: "", options: .caseInsensitive)
        } else if let (weekday, range, wantsNext) = matchWeekday(text) {
            day = nextOccurrence(of: weekday, from: now, calendar: calendar, forceNextWeek: wantsNext)
            dayMatched = true
            text.removeSubrange(range)
        }

        // 4. Time + optional end: "1pm", "3-3:30", "at 9:00", "9am to 10".
        guard let time = matchTimeRange(text) else {
            // A time-shaped token that FAILED to parse (e.g. "25pm", "at 9:99") → don't guess;
            // return nil so the user retypes rather than get a silent all-day/midnight event
            // (audit MED). Only fall through to all-day when no time was attempted at all.
            if looksLikeTimeAttempt(text) { return nil }
            guard dayMatched else { return nil }   // no day, no time → just a title, nothing to schedule
            let title = cleanTitle(text)
            guard !title.isEmpty else { return nil }
            let end = calendar.date(byAdding: .day, value: 1, to: day) ?? day
            return EventDraft(title: title, start: day, end: end, isAllDay: true,
                              location: location, attendees: attendees)
        }
        text.removeSubrange(time.range)

        let start = calendar.date(bySettingHour: time.startHour, minute: time.startMinute,
                                  second: 0, of: day) ?? day
        let end: Date
        if let (eh, em) = time.end {
            end = calendar.date(bySettingHour: eh, minute: em, second: 0, of: day) ?? start.addingTimeInterval(1800)
        } else {
            end = start.addingTimeInterval(30 * 60)   // default 30-minute call
        }

        let title = cleanTitle(text)
        guard !title.isEmpty else { return nil }
        return EventDraft(title: title, start: start, end: max(end, start.addingTimeInterval(300)),
                          isAllDay: false, location: location, attendees: attendees)
    }

    // MARK: - title cleanup

    static func cleanTitle(_ s: String) -> String {
        var t = s
        // Strip stray connective words left after removing time/day/attendees.
        for w in ["\\bat\\b", "\\bon\\b", "\\bfrom\\b", "\\bto\\b", "\\bnext\\b"] {
            t = t.replacingOccurrences(of: w, with: " ", options: [.regularExpression, .caseInsensitive])
        }
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "-,")))
    }

    // MARK: - weekday

    static let weekdayNames: [(names: [String], index: Int)] = [
        (["sunday", "sun"], 1), (["monday", "mon"], 2), (["tuesday", "tue", "tues"], 3),
        (["wednesday", "wed"], 4), (["thursday", "thu", "thurs"], 5),
        (["friday", "fri"], 6), (["saturday", "sat"], 7),
    ]

    static func matchWeekday(_ text: String) -> (weekday: Int, range: Range<String.Index>, wantsNext: Bool)? {
        let lower = text.lowercased()
        for (names, idx) in weekdayNames {
            for n in names {
                if let r = lower.range(of: "\\b\(n)\\b", options: .regularExpression) {
                    // "next monday" pushes to the following week.
                    let before = lower[..<r.lowerBound]
                    let wantsNext = before.hasSuffix("next ") || before.hasSuffix("next")
                    guard let mapped = Range(NSRange(r, in: lower), in: text) else { continue }
                    return (idx, mapped, wantsNext)
                }
            }
        }
        return nil
    }

    static func nextOccurrence(of weekday: Int, from now: Date, calendar: Calendar,
                               forceNextWeek: Bool) -> Date {
        let today = calendar.startOfDay(for: now)
        let cur = calendar.component(.weekday, from: today)
        var delta = (weekday - cur + 7) % 7          // 0 = today, else the imminent occurrence
        // "next <weekday>" always pushes a full week past the imminent one (so from Wed,
        // "next Friday" = the Friday of next week, and "next Wednesday" = 7 days out).
        if forceNextWeek { delta += 7 }
        return calendar.date(byAdding: .day, value: delta, to: today) ?? today
    }

    // MARK: - time

    struct TimeMatch { let startHour: Int; let startMinute: Int
                       let end: (Int, Int)?; let range: Range<String.Index> }

    /// Matches "1pm", "9:30am", "3-3:30", "9am to 10:30", "at 14:00".
    static func matchTimeRange(_ text: String) -> TimeMatch? {
        let pattern = #"(?:at\s+)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\s*(?:(?:-|–|to)\s*(\d{1,2})(?::(\d{2}))?\s*(am|pm)?)?"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = text as NSString
        let all = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        for m in all {
            let hourStr = ns.substring(with: m.range(at: 1))
            guard let h0 = Int(hourStr), h0 >= 0, h0 <= 23 else { continue }
            // Require SOMETHING time-like: an am/pm, a colon, or a range — a bare "3" in "top 3
            // items" must not become 3:00.
            let hasMeridiem = m.range(at: 3).location != NSNotFound
            let hasColon = m.range(at: 2).location != NSNotFound
            let hasRange = m.range(at: 4).location != NSNotFound
            guard hasMeridiem || hasColon || hasRange else { continue }

            let startMeridiem: String? = m.range(at: 3).location != NSNotFound
                ? ns.substring(with: m.range(at: 3)) : nil
            let endMeridiem: String? = m.range(at: 6).location != NSNotFound
                ? ns.substring(with: m.range(at: 6)) : nil
            let startMin = m.range(at: 2).location != NSNotFound ? (Int(ns.substring(with: m.range(at: 2))) ?? 0) : 0
            guard startMin < 60 else { continue }

            // Start meridiem: explicit, else inherit from the END's meridiem (audit HIGH:
            // "3 to 4pm" must be 3 PM–4 PM, not 03:00–16:00). Only inherit when it doesn't
            // put start after end on the clock.
            var startHour = h0
            if let sm = startMeridiem {
                startHour = to24(h0, sm)
            } else if let em = endMeridiem, m.range(at: 4).location != NSNotFound,
                      let eh0 = Int(ns.substring(with: m.range(at: 4))) {
                let inferred = to24(h0, em)
                let endH = to24(eh0, em)
                if inferred <= endH { startHour = inferred }   // "3 to 4pm" → 15; "11 to 1pm" keeps 11
            }

            var end: (Int, Int)? = nil
            if m.range(at: 4).location != NSNotFound, let eh0 = Int(ns.substring(with: m.range(at: 4))) {
                var eh = eh0
                let em = m.range(at: 5).location != NSNotFound ? (Int(ns.substring(with: m.range(at: 5))) ?? 0) : 0
                guard em < 60, eh0 <= 23 else { continue }
                if let endM = endMeridiem {
                    eh = to24(eh0, endM)
                } else if let sm = startMeridiem {
                    eh = to24(eh0, sm)                          // inherit start's am/pm
                    // "11am to 1" (→1am) and "11am to 12" (→12am/midnight) read BACKWARD.
                    // Flip the end to PM so the range goes forward (verify-audit LOW).
                    if eh * 60 + em < startHour * 60 + startMin, eh0 >= 1, eh0 <= 12 {
                        eh = to24(eh0, "pm")                    // 12→noon(12), 1→13, …
                    }
                }
                end = (eh, em)
            }
            guard let range = Range(m.range, in: text) else { continue }
            return TimeMatch(startHour: startHour, startMinute: startMin, end: end, range: range)
        }
        return nil
    }

    static func to24(_ hour12: Int, _ meridiem: String) -> Int {
        let pm = meridiem.lowercased().hasPrefix("p")
        if pm { return hour12 == 12 ? 12 : hour12 + 12 }
        return hour12 == 12 ? 0 : hour12
    }

    /// A time was clearly ATTEMPTED (am/pm or HH:MM) even though matchTimeRange rejected it —
    /// so we refuse rather than silently produce an all-day/midnight event.
    static func looksLikeTimeAttempt(_ text: String) -> Bool {
        text.range(of: #"\d{1,2}\s*(?:am|pm)\b|\d{1,2}:\d{2}"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }
}
