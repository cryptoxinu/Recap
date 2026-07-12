import Testing
import Foundation
@testable import CallBrainCore

/// Calendar v3 — the week-view overlap layout. Notion/Google semantics: events in an overlap
/// CLUSTER share the column width equally; separate clusters are independent (a lone 7 AM
/// event stays full width even when 9 AM has a pileup). Geometry-free: minutes from local
/// midnight, the view maps minutes → points.
@Suite("Day event layout (v3)")
struct DayEventLayoutTests {

    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        c.firstWeekday = 1
        return c
    }

    private func date(_ ymd: String, _ hm: String) -> Date {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"; df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return df.date(from: "\(ymd) \(hm)")!
    }

    private func event(_ id: String, _ startHM: String, _ endHM: String,
                       ymd: String = "2026-07-01", endYMD: String? = nil,
                       allDay: Bool = false) -> CalendarEvent {
        CalendarEvent(stableID: id, sourceKind: .eventKit, calendarName: "Work",
                      title: id, start: date(ymd, startHM), end: date(endYMD ?? ymd, endHM),
                      attendees: [], isAllDay: allDay)
    }

    private func place(_ events: [CalendarEvent], ymd: String = "2026-07-01") -> [DayEventLayout.Placed] {
        DayEventLayout.place(events, on: date(ymd, "12:00"), calendar: cal)
    }

    private func placed(_ id: String, in placed: [DayEventLayout.Placed]) -> DayEventLayout.Placed? {
        placed.first { $0.event.stableID == id }
    }

    @Test("single event fills the column")
    func testSingle() {
        let out = place([event("a", "09:00", "10:00")])
        #expect(out.count == 1)
        #expect(out[0].column == 0 && out[0].columnCount == 1)
        #expect(out[0].startMinute == 540 && out[0].endMinute == 600)
        #expect(out[0].widthFraction == 1.0 && out[0].xFraction == 0.0)
    }

    @Test("back-to-back events do NOT overlap — both full width")
    func testBackToBack() {
        let out = place([event("a", "09:00", "10:00"), event("b", "10:00", "11:00")])
        #expect(out.count == 2)
        #expect(out.allSatisfy { $0.columnCount == 1 })
    }

    @Test("simple overlap splits into two shared-width columns")
    func testSimpleOverlap() {
        let out = place([event("a", "09:00", "10:00"), event("b", "09:30", "10:30")])
        #expect(placed("a", in: out)?.column == 0)
        #expect(placed("b", in: out)?.column == 1)
        #expect(out.allSatisfy { $0.columnCount == 2 })
    }

    @Test("a freed column is reused within the cluster")
    func testColumnReuse() {
        // A(9-10) col0, B(9:30-11) col1, C(10:15-11) reuses col0 — one cluster of width 2.
        let out = place([event("a", "09:00", "10:00"),
                         event("b", "09:30", "11:00"),
                         event("c", "10:15", "11:00")])
        #expect(placed("a", in: out)?.column == 0)
        #expect(placed("b", in: out)?.column == 1)
        #expect(placed("c", in: out)?.column == 0)
        #expect(out.allSatisfy { $0.columnCount == 2 })
    }

    @Test("triple pileup → three columns, deterministic order")
    func testTriplePileup() {
        let out = place([event("c", "09:00", "10:00"),
                         event("a", "09:00", "10:00"),
                         event("b", "09:00", "10:00")])
        #expect(out.allSatisfy { $0.columnCount == 3 })
        // Equal start+end → ties break by id ascending, so a|b|c left→right.
        #expect(placed("a", in: out)?.column == 0)
        #expect(placed("b", in: out)?.column == 1)
        #expect(placed("c", in: out)?.column == 2)
        #expect(abs((placed("b", in: out)?.xFraction ?? 0) - 1.0 / 3.0) < 0.0001)
    }

    @Test("zero-duration events inflate to the minimum slot and collide honestly")
    func testZeroDurationInflation() {
        // 9:00 point event inflates to 9:00-9:15; 9:10-9:40 genuinely collides on screen.
        let out = place([event("a", "09:00", "09:00"), event("b", "09:10", "09:40")])
        #expect(placed("a", in: out)?.endMinute == 555)
        #expect(out.allSatisfy { $0.columnCount == 2 })
    }

    @Test("cross-midnight event clamps on its start day AND appears on the next day")
    func testCrossMidnight() {
        let e = event("a", "23:00", "01:00", ymd: "2026-07-01", endYMD: "2026-07-02")
        let day1 = place([e], ymd: "2026-07-01")
        #expect(day1.count == 1)
        #expect(day1[0].startMinute == 1380 && day1[0].endMinute == 1440)
        let day2 = place([e], ymd: "2026-07-02")
        #expect(day2.count == 1)
        #expect(day2[0].startMinute == 0 && day2[0].endMinute == 60)
        let day3 = place([e], ymd: "2026-07-03")
        #expect(day3.isEmpty)
    }

    @Test("all-day events are excluded; timed siblings unaffected")
    func testAllDayExcluded() {
        let out = place([event("a", "00:00", "23:59", allDay: true),
                         event("b", "09:00", "10:00")])
        #expect(out.count == 1)
        #expect(out[0].event.stableID == "b" && out[0].columnCount == 1)
    }

    @Test("fall-back DST repeated hour keeps the event's real duration (audit MED)")
    func testDSTRepeatedHour() {
        // 2026-11-01 America/Los_Angeles: 2:00 PDT falls back to 1:00 PST — wall-clock 1:30
        // happens twice. An event 1:00 PDT → 1:00 PST is 60 real minutes but both endpoints
        // read as wall-clock 1:00; the layout must keep the 60-minute height, not collapse
        // to the 15-minute minimum.
        let start = Date(timeIntervalSince1970: 1_793_520_000)   // 2026-11-01 08:00Z = 1:00 PDT
        let end = Date(timeIntervalSince1970: 1_793_523_600)     // 2026-11-01 09:00Z = 1:00 PST
        let e = CalendarEvent(stableID: "dst", sourceKind: .eventKit, calendarName: "Work",
                              title: "dst", start: start, end: end, attendees: [], isAllDay: false)
        let out = DayEventLayout.place([e], on: start, calendar: cal)
        #expect(out.count == 1)
        #expect(out[0].endMinute - out[0].startMinute == 60)
    }

    @Test("fall-back DST shrunken (not collapsed) wall span also keeps real duration")
    func testDSTShrunkenSpan() {
        // 1:30 PDT → 1:45 PST is 75 real minutes but reads as a 15-minute wall span.
        let start = Date(timeIntervalSince1970: 1_793_521_800)   // 2026-11-01 08:30Z = 1:30 PDT
        let end = Date(timeIntervalSince1970: 1_793_526_300)     // 2026-11-01 09:45Z = 1:45 PST
        let e = CalendarEvent(stableID: "dst2", sourceKind: .eventKit, calendarName: "Work",
                              title: "dst2", start: start, end: end, attendees: [], isAllDay: false)
        let out = DayEventLayout.place([e], on: start, calendar: cal)
        #expect(out.count == 1)
        #expect(out[0].endMinute - out[0].startMinute == 75)
    }

    @Test("clusters are independent — a solo event keeps full width beside a pileup")
    func testClusterIndependence() {
        let out = place([event("solo", "07:00", "08:00"),
                         event("a", "09:00", "10:00"),
                         event("b", "09:30", "10:30")])
        #expect(placed("solo", in: out)?.columnCount == 1)
        #expect(placed("a", in: out)?.columnCount == 2)
        #expect(placed("b", in: out)?.columnCount == 2)
    }
}
