import Testing
import Foundation
@testable import CallBrainCore

/// Calendar v3 — pure date/bucketing math behind the week grid, visibility toggles, and the
/// agenda's Upcoming groups. All functions take an explicit Calendar so tests are
/// machine-independent (fixed gregorian + Los Angeles + Sunday first).
@Suite("Calendar math (v3)")
struct CalendarMathTests {

    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        c.firstWeekday = 1   // Sunday
        return c
    }

    private func date(_ ymd: String, _ hm: String = "12:00") -> Date {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"; df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return df.date(from: "\(ymd) \(hm)")!
    }

    private func event(_ id: String, _ startYMD: String, _ startHM: String,
                       endYMD: String? = nil, endHM: String = "13:00",
                       calendarName: String = "Work", allDay: Bool = false) -> CalendarEvent {
        CalendarEvent(stableID: id, sourceKind: .eventKit, calendarName: calendarName,
                      title: id, start: date(startYMD, startHM),
                      end: date(endYMD ?? startYMD, endHM),
                      attendees: [], isAllDay: allDay)
    }

    // MARK: - week math

    @Test("weekDays returns 7 consecutive days starting on firstWeekday, containing the anchor")
    func testWeekDays() {
        // 2026-07-01 is a Wednesday; Sunday-first week is Jun 28 … Jul 4.
        let days = CalendarMath.weekDays(anchor: date("2026-07-01"), calendar: cal)
        #expect(days.count == 7)
        #expect(TimeCode.ymd(days.first!, calendar: cal) == "2026-06-28")
        #expect(TimeCode.ymd(days.last!, calendar: cal) == "2026-07-04")
        #expect(days.contains { TimeCode.ymd($0, calendar: cal) == "2026-07-01" })
    }

    @Test("weekDays is stable across the anchor's position in the week")
    func testWeekDaysStable() {
        let fromSunday = CalendarMath.weekDays(anchor: date("2026-06-28"), calendar: cal)
        let fromSaturday = CalendarMath.weekDays(anchor: date("2026-07-04"), calendar: cal)
        #expect(fromSunday.map { TimeCode.ymd($0, calendar: cal) }
                == fromSaturday.map { TimeCode.ymd($0, calendar: cal) })
    }

    @Test("weekInterval covers exactly the 7 weekDays")
    func testWeekInterval() {
        let anchor = date("2026-07-01")
        let interval = CalendarMath.weekInterval(anchor: anchor, calendar: cal)
        let days = CalendarMath.weekDays(anchor: anchor, calendar: cal)
        #expect(interval.start == cal.startOfDay(for: days.first!))
        #expect(interval.end == cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: days.last!)))
        #expect(days.allSatisfy { interval.contains($0) })
    }

    // MARK: - cross-midnight intersection

    @Test("eventsIntersecting includes a cross-midnight event on both days, not a third")
    func testIntersection() {
        let e = event("a", "2026-07-01", "23:00", endYMD: "2026-07-02", endHM: "01:00")
        #expect(CalendarMath.eventsIntersecting(day: date("2026-07-01"), events: [e], calendar: cal).count == 1)
        #expect(CalendarMath.eventsIntersecting(day: date("2026-07-02"), events: [e], calendar: cal).count == 1)
        #expect(CalendarMath.eventsIntersecting(day: date("2026-07-03"), events: [e], calendar: cal).isEmpty)
    }

    @Test("an event ending exactly at midnight does not bleed into the next day")
    func testMidnightBoundary() {
        let e = event("a", "2026-07-01", "22:00", endYMD: "2026-07-02", endHM: "00:00")
        #expect(CalendarMath.eventsIntersecting(day: date("2026-07-01"), events: [e], calendar: cal).count == 1)
        #expect(CalendarMath.eventsIntersecting(day: date("2026-07-02"), events: [e], calendar: cal).isEmpty)
    }

    // MARK: - visibility buckets

    @Test("hiding a calendar removes its events from visible, byDay, and daysWithEvents")
    func testBucketsVisibility() {
        let events = [event("a", "2026-07-01", "09:00"),
                      event("b", "2026-07-01", "10:00", calendarName: "Personal"),
                      event("c", "2026-07-02", "09:00", calendarName: "Personal")]
        let b = CalendarMath.buckets(events: events, hidden: ["Personal"], calendar: cal)
        #expect(b.visible.map(\.stableID) == ["a"])
        #expect(b.byDay["2026-07-01"]?.map(\.stableID) == ["a"])
        // Jul 2's ONLY event is hidden → the day drops out entirely (mini-month dot case).
        #expect(b.byDay["2026-07-02"] == nil)
        #expect(b.daysWithEvents == ["2026-07-01"])
    }

    @Test("empty hidden set is identity")
    func testBucketsIdentity() {
        let events = [event("a", "2026-07-01", "09:00"), event("b", "2026-07-02", "10:00")]
        let b = CalendarMath.buckets(events: events, hidden: [], calendar: cal)
        #expect(b.visible.count == 2)
        #expect(b.daysWithEvents == ["2026-07-01", "2026-07-02"])
    }

    @Test("a multi-day event appears in EVERY day it intersects (v2 bug: start day only)")
    func testBucketsMultiDay() {
        let conference = event("conf", "2026-07-01", "09:00", endYMD: "2026-07-03", endHM: "17:00")
        let b = CalendarMath.buckets(events: [conference], hidden: [], calendar: cal)
        #expect(b.daysWithEvents == ["2026-07-01", "2026-07-02", "2026-07-03"])
        #expect(b.byDay["2026-07-02"]?.map(\.stableID) == ["conf"])
    }

    @Test("a months-long event clamped to the loaded window still covers every window day (audit MED)")
    func testBucketsLongEventClampedToWindow() {
        // 100-day OOO starting 50 days BEFORE the window — without clamping, day iteration
        // burns its hop budget before reaching the visible days and the tail vanishes.
        let ooo = event("ooo", "2026-05-13", "00:00", endYMD: "2026-08-21", endHM: "17:00")
        let window = DateInterval(start: date("2026-07-01", "00:00"), end: date("2026-07-15", "00:00"))
        let b = CalendarMath.buckets(events: [ooo], hidden: [], within: window, calendar: cal)
        #expect(b.byDay["2026-07-01"]?.map(\.stableID) == ["ooo"])
        #expect(b.byDay["2026-07-14"]?.map(\.stableID) == ["ooo"])
        #expect(b.byDay["2026-06-30"] == nil)   // outside the window — not bucketed
        #expect(b.byDay["2026-07-15"] == nil)
    }

    @Test("within a day, all-day events sort first, then by start time")
    func testBucketsDayOrder() {
        let events = [event("late", "2026-07-01", "15:00"),
                      event("early", "2026-07-01", "08:00"),
                      event("birthday", "2026-07-01", "00:00", endHM: "23:59", allDay: true)]
        let b = CalendarMath.buckets(events: events, hidden: [], calendar: cal)
        #expect(b.byDay["2026-07-01"]?.map(\.stableID) == ["birthday", "early", "late"])
    }

    // MARK: - agenda upcoming

    @Test("upcomingByDay groups future timed events ascending by day, excluding today and ended")
    func testUpcomingByDay() {
        let now = date("2026-07-02", "12:00")
        let events = [event("ended", "2026-07-01", "09:00"),
                      event("today", "2026-07-02", "15:00"),
                      event("tomorrow2", "2026-07-03", "14:00"),
                      event("tomorrow1", "2026-07-03", "09:00"),
                      event("nextweek", "2026-07-08", "09:00"),
                      event("allday", "2026-07-05", "00:00", endHM: "23:59", allDay: true)]
        let groups = CalendarMath.upcomingByDay(events: events, now: now, calendar: cal)
        #expect(groups.map(\.ymd) == ["2026-07-03", "2026-07-08"])
        #expect(groups.first?.events.map(\.stableID) == ["tomorrow1", "tomorrow2"])
    }

    @Test("upcomingByDay lists a today-starting overnight event under tomorrow too (final-gate MED)")
    func testUpcomingContinuation() {
        let now = date("2026-07-02", "12:00")
        let overnight = event("late", "2026-07-02", "23:00", endYMD: "2026-07-03", endHM: "01:00")
        let groups = CalendarMath.upcomingByDay(events: [overnight], now: now, calendar: cal)
        #expect(groups.map(\.ymd) == ["2026-07-03"])
        #expect(groups.first?.events.map(\.stableID) == ["late"])
    }

    @Test("displaySpan clamps to the rendered day and flags continuation")
    func testDisplaySpan() {
        let e = event("a", "2026-07-01", "23:00", endYMD: "2026-07-02", endHM: "01:00")
        let day2 = CalendarMath.displaySpan(e, on: date("2026-07-02", "12:00"), calendar: cal)
        #expect(TimeCode.ymd(day2.start, calendar: cal) == "2026-07-02")
        #expect(cal.component(.hour, from: day2.start) == 0)
        #expect(cal.component(.hour, from: day2.end) == 1)
        #expect(day2.continuesBefore && !day2.continuesAfter)
        let day1 = CalendarMath.displaySpan(e, on: date("2026-07-01", "12:00"), calendar: cal)
        #expect(cal.component(.hour, from: day1.start) == 23)
        #expect(!day1.continuesBefore && day1.continuesAfter)
    }
}
