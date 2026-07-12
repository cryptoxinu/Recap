import Foundation

/// Calendar v3 — pure date/bucketing math behind the week grid, the visibility toggles, and
/// the agenda's Upcoming groups. Every function takes an explicit Calendar so behavior is
/// testable independent of machine settings.
public enum CalendarMath {

    // MARK: - week math

    /// The 7 consecutive days of the anchor's week, starting on `calendar.firstWeekday`.
    public static func weekDays(anchor: Date, calendar: Calendar = .current) -> [Date] {
        guard let interval = calendar.dateInterval(of: .weekOfYear, for: anchor) else { return [anchor] }
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: interval.start) }
    }

    /// [weekStart, weekStart + 7 days) — the load/containment interval for the week view.
    public static func weekInterval(anchor: Date, calendar: Calendar = .current) -> DateInterval {
        calendar.dateInterval(of: .weekOfYear, for: anchor)
            ?? DateInterval(start: calendar.startOfDay(for: anchor), duration: 7 * 86_400)
    }

    /// The full-weeks interval a month GRID displays (leading/trailing adjacent-month days
    /// included) — what `ensureLoaded` must have in `loadedRange` for month mode.
    public static func monthGridInterval(anchor: Date, calendar: Calendar = .current) -> DateInterval {
        guard let month = calendar.dateInterval(of: .month, for: anchor),
              let firstWeek = calendar.dateInterval(of: .weekOfYear, for: month.start),
              let lastWeek = calendar.dateInterval(of: .weekOfYear, for: month.end.addingTimeInterval(-1))
        else { return weekInterval(anchor: anchor, calendar: calendar) }
        return DateInterval(start: firstWeek.start, end: lastWeek.end)
    }

    // MARK: - intersection (cross-midnight aware)

    /// Events that overlap the given day at all — a 23:00→01:00 event appears on BOTH days.
    /// An event ending exactly at midnight does not bleed into the next day.
    public static func eventsIntersecting(day: Date, events: [CalendarEvent],
                                          calendar: Calendar = .current) -> [CalendarEvent] {
        let dayStart = calendar.startOfDay(for: day)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return [] }
        return events.filter { ev in
            ev.start < dayEnd && (ev.end > dayStart || (ev.start == ev.end && ev.start >= dayStart))
        }
    }

    // MARK: - visibility buckets (the hub's cache rebuild)

    public struct DayBuckets: Sendable {
        public let visible: [CalendarEvent]
        public let byDay: [String: [CalendarEvent]]    // "YYYY-MM-DD" → all-day first, then by start
        public let daysWithEvents: Set<String>
    }

    /// Filters hidden calendars, then buckets each visible event into EVERY day it intersects
    /// (v2 bucketed by start day only, so a 3-day conference vanished after day 1).
    /// `within` clamps day iteration to the loaded window (audit MED: a months-long event
    /// starting before the window must still cover every visible day — pass the hub's range).
    public static func buckets(events: [CalendarEvent], hidden: Set<String>,
                               within: DateInterval? = nil,
                               calendar: Calendar = .current) -> DayBuckets {
        let visible = events.filter { !hidden.contains($0.calendarName) }
        var byDay: [String: [CalendarEvent]] = [:]
        for e in visible {
            var day = calendar.startOfDay(for: e.start)
            // end-1s so an event ending exactly at midnight stays on its last real day.
            var lastDay = calendar.startOfDay(for: e.end > e.start ? e.end.addingTimeInterval(-1) : e.end)
            if let within {
                day = max(day, calendar.startOfDay(for: within.start))
                lastDay = min(lastDay, calendar.startOfDay(for: within.end.addingTimeInterval(-1)))
            }
            var hops = 0
            while day <= lastDay, hops < 366 {   // absolute runaway guard (never binds when clamped)
                byDay[TimeCode.ymd(day, calendar: calendar), default: []].append(e)
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next; hops += 1
            }
        }
        for (k, v) in byDay {
            byDay[k] = v.sorted { a, b in
                if a.isAllDay != b.isAllDay { return a.isAllDay }
                if a.start != b.start { return a.start < b.start }
                return a.id < b.id
            }
        }
        return DayBuckets(visible: visible, byDay: byDay, daysWithEvents: Set(byDay.keys))
    }

    // MARK: - agenda upcoming

    public struct DayGroup: Sendable, Equatable {
        public let ymd: String
        public let events: [CalendarEvent]
    }

    /// Future timed events AFTER today (the agenda's Today section owns today), grouped
    /// ascending by day. All-day events are excluded — Upcoming is about joinable calls.
    /// Groups by EVERY intersecting day (final-gate MED: a 23:00→01:00 event starting today
    /// belongs to tomorrow's section too — matching `events(onYMD:)` semantics).
    public static func upcomingByDay(events: [CalendarEvent], now: Date,
                                     calendar: Calendar = .current, limit: Int = 30) -> [DayGroup] {
        let today = TimeCode.ymd(now, calendar: calendar)
        var byDay: [String: [CalendarEvent]] = [:]
        for e in events where !e.isAllDay && e.end > now {
            var day = calendar.startOfDay(for: e.start)
            let lastDay = calendar.startOfDay(for: e.end > e.start ? e.end.addingTimeInterval(-1) : e.end)
            var hops = 0
            while day <= lastDay, hops < 366 {
                let ymd = TimeCode.ymd(day, calendar: calendar)
                if ymd > today { byDay[ymd, default: []].append(e) }
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next; hops += 1
            }
        }
        return byDay.keys.sorted().prefix(limit).map { ymd in
            DayGroup(ymd: ymd, events: byDay[ymd]!.sorted {
                $0.start != $1.start ? $0.start < $1.start : $0.id < $1.id
            })
        }
    }

    // MARK: - day-scoped display

    /// "YYYY-MM-DD" → a Date inside that local day (noon — immune to DST-midnight edges).
    public static func date(fromYMD ymd: String, calendar: Calendar = .current) -> Date? {
        let parts = ymd.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var c = DateComponents()
        c.year = parts[0]; c.month = parts[1]; c.day = parts[2]; c.hour = 12
        return calendar.date(from: c)
    }

    /// The event's span clamped to the rendered day (final-gate MED: a 23:00→01:00 block on
    /// tomorrow's column sits at midnight but its label said "11 PM" — day-scoped surfaces
    /// must label the clamped span).
    public static func displaySpan(_ e: CalendarEvent, on day: Date,
                                   calendar: Calendar = .current)
        -> (start: Date, end: Date, continuesBefore: Bool, continuesAfter: Bool) {
        let dayStart = calendar.startOfDay(for: day)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        return (max(e.start, dayStart), min(e.end, dayEnd),
                e.start < dayStart, e.end > dayEnd)
    }
}
