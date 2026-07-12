import Testing
import Foundation
@testable import CallBrainCore

/// Calendar v4 — natural-language quick-add parsing. Fixed clock + timezone so assertions are
/// machine-independent. Wed 2026-07-01 12:00 local is the reference "now".
@Suite("Event draft parser (v4)")
struct EventDraftParserTests {

    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        c.firstWeekday = 1
        return c
    }
    private var now: Date {   // Wednesday, 2026-07-01 12:00 PDT
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH:mm"
        df.locale = Locale(identifier: "en_US_POSIX"); df.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return df.date(from: "2026-07-01 12:00")!
    }

    private func parse(_ s: String) -> EventDraft? { EventDraftParser.parse(s, now: now, calendar: cal) }
    private func hm(_ d: Date) -> (Int, Int) {
        let c = cal.dateComponents([.hour, .minute], from: d); return (c.hour ?? 0, c.minute ?? 0)
    }
    private func ymd(_ d: Date) -> String {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        df.timeZone = cal.timeZone; df.locale = Locale(identifier: "en_US_POSIX"); return df.string(from: d)
    }

    @Test("time only defaults to today, 30-minute duration")
    func testTimeOnly() {
        let d = parse("call at 3pm")!
        #expect(d.title == "call")
        #expect(ymd(d.start) == "2026-07-01")
        #expect(hm(d.start) == (15, 0))
        #expect(hm(d.end) == (15, 30))
    }

    @Test("tomorrow + explicit range")
    func testTomorrowRange() {
        let d = parse("sync tomorrow 3-3:30")!
        #expect(d.title == "sync")
        #expect(ymd(d.start) == "2026-07-02")
        #expect(hm(d.start) == (3, 0))
        #expect(hm(d.end) == (3, 30))
    }

    @Test("weekday name resolves to the next such day; with attendee + location")
    func testWeekdayAttendeeLocation() {
        let d = parse("lunch with Sam friday 1pm zoom")!
        #expect(d.title.lowercased().contains("lunch"))
        #expect(ymd(d.start) == "2026-07-03")   // Fri after Wed
        #expect(hm(d.start) == (13, 0))
        #expect(d.attendees == ["Sam"])
        #expect(d.location?.lowercased() == "zoom")
    }

    @Test("am/pm inheritance across a range: '9 to 10:30am'")
    func testMeridiemInheritance() {
        let d = parse("standup 9 to 10:30am monday")!
        #expect(ymd(d.start) == "2026-07-06")   // Mon after Wed
        #expect(hm(d.start) == (9, 0))
        #expect(hm(d.end) == (10, 30))
    }

    @Test("multiple attendees split on and / &")
    func testMultipleAttendees() {
        let d = parse("review with Alex and Sam 2pm")!
        #expect(d.attendees == ["Alex", "Sam"])
        #expect(hm(d.start) == (14, 0))
    }

    @Test("24-hour time")
    func test24h() {
        let d = parse("deploy at 14:00")!
        #expect(hm(d.start) == (14, 0))
    }

    @Test("no time and no day → nil (just a title, nothing to schedule)")
    func testNoTimeNil() {
        #expect(parse("think about pricing") == nil)
    }

    @Test("bare number in prose is not a time")
    func testBareNumberNotTime() {
        // "top 3 things" has no am/pm, colon, or range → no time → (no day) → nil
        #expect(parse("review top 3 things") == nil)
    }

    @Test("'next friday' pushes a full week past the imminent friday")
    func testNextWeekday() {
        // From Wed 2026-07-01: imminent Fri = 07-03; "next Friday" = 07-10.
        let d = parse("offsite next friday 10am")!
        #expect(ymd(d.start) == "2026-07-10")
        #expect(hm(d.start) == (10, 0))
    }

    @Test("'11am to 1' spans to 1 PM, not collapsing across noon (final-audit LOW)")
    func testCrossNoonRange() {
        let d = parse("lunch 11am to 1")!
        #expect(hm(d.start) == (11, 0))
        #expect(hm(d.end) == (13, 0))
    }

    @Test("'11am to 12' ends at noon, not midnight (verify-audit LOW)")
    func testCrossNoonToTwelve() {
        let d = parse("lunch 11am to 12")!
        #expect(hm(d.start) == (11, 0))
        #expect(hm(d.end) == (12, 0))
    }

    @Test("'meet with Sam' keeps the verb in the title (audit HIGH: bare 'meet' ≠ location)")
    func testMeetVerbNotLocation() {
        let d = parse("meet with Sam friday 1pm")!
        #expect(d.title.lowercased().contains("meet"))
        #expect(d.attendees == ["Sam"])
        #expect(d.location == nil)
    }

    @Test("'3 to 4pm' is 3 PM–4 PM, not 03:00–16:00 (audit HIGH: start inherits end meridiem)")
    func testStartInheritsEndMeridiem() {
        let d = parse("review 3 to 4pm")!
        #expect(hm(d.start) == (15, 0))
        #expect(hm(d.end) == (16, 0))
    }

    @Test("'at <place>' becomes the location, not part of the title (audit MED)")
    func testAtPlaceLocation() {
        let d = parse("lunch with Sam at Tartine friday 1pm")!
        #expect(d.location == "Tartine")
        #expect(!d.title.lowercased().contains("tartine"))
        #expect(d.attendees == ["Sam"])
    }

    @Test("an invalid time is refused, not silently made all-day (audit MED)")
    func testInvalidTimeRefused() {
        #expect(parse("standup friday 25pm") == nil)
    }

    @Test("day named but no time → all-day event")
    func testAllDay() {
        let d = parse("conference friday")!
        #expect(d.isAllDay)
        #expect(ymd(d.start) == "2026-07-03")
        #expect(d.title.lowercased().contains("conference"))
    }
}
