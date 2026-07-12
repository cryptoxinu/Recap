import Testing
import Foundation
@testable import CallBrainCore

/// Calendar initiative C1 — the pure event↔meeting matcher. Conservative like
/// CrossSourceLinker: link only when confident AND unambiguous.
@Suite("Event↔meeting linker (C1)")
struct EventMeetingLinkerTests {

    private func date(_ ymd: String, _ hm: String) -> Date {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"; df.locale = Locale(identifier: "en_US_POSIX")
        return df.date(from: "\(ymd) \(hm)")!
    }

    private func event(_ id: String, _ title: String, _ ymd: String, _ hm: String,
                       attendees: [String] = []) -> CalendarEvent {
        CalendarEvent(stableID: id, sourceKind: .eventKit, calendarName: "Work",
                      title: title, start: date(ymd, hm),
                      end: date(ymd, hm).addingTimeInterval(1800),
                      attendees: attendees, isAllDay: false)
    }

    private func candidate(_ id: String, _ title: String, _ ymd: String, startHM: String?,
                           people: [String] = []) -> EventMeetingLinker.MeetingCandidate {
        EventMeetingLinker.MeetingCandidate(
            meetingID: id, title: title, date: ymd,
            startedAt: startHM.map { date(ymd, $0) }, people: people)
    }

    @Test("same day + close start time + title overlap links")
    func testStrongMatchLinks() {
        let links = EventMeetingLinker.links(
            events: [event("e1", "Ambient Engineering Standup", "2026-07-01", "17:30")],
            meetings: [candidate("m1", "Ambient Engineering Standup", "2026-07-01", startHM: "17:29")])
        #expect(links.count == 1)
        #expect(links.first?.eventID == "eventKit|e1")   // source-qualified, stable across providers
        #expect(links.first?.meetingID == "m1")
        #expect((links.first?.confidence ?? 0) >= 0.8)
    }

    @Test("different day never links, even with identical titles")
    func testDayGate() {
        let links = EventMeetingLinker.links(
            events: [event("e1", "Morning Sync", "2026-07-01", "09:00")],
            meetings: [candidate("m1", "Morning Sync", "2026-06-30", startHM: "09:00")])
        #expect(links.isEmpty)
    }

    @Test("ambiguity blocks: two same-day events equally close to one meeting → no link")
    func testAmbiguityBlocks() {
        let links = EventMeetingLinker.links(
            events: [event("e1", "Sync", "2026-07-01", "09:00"),
                     event("e2", "Sync", "2026-07-01", "09:05")],
            meetings: [candidate("m1", "Sync", "2026-07-01", startHM: "09:02")])
        #expect(links.isEmpty)
    }

    @Test("attendee↔people overlap links a renamed call without title overlap")
    func testAttendeeSignal() {
        let links = EventMeetingLinker.links(
            events: [event("e1", "Weekly 1:1", "2026-07-01", "14:00",
                           attendees: ["Riley Novak", "Alex King"])],
            meetings: [candidate("m1", "Billing & Render Sync", "2026-07-01", startHM: "14:01",
                                 people: ["Riley Novak", "Priya"])])
        #expect(links.count == 1)
    }

    @Test("a meeting without start time can still link on title, at lower confidence")
    func testNoStartTimeTitleOnly() {
        let links = EventMeetingLinker.links(
            events: [event("e1", "Ambient Partnership & Sales Strategy", "2026-06-25", "11:00")],
            meetings: [candidate("m1", "Ambient Partnership & Sales Strategy", "2026-06-25", startHM: nil)])
        #expect(links.count == 1)
        #expect((links.first?.confidence ?? 1) < 0.9)
    }

    @Test("containment links: event 'morning sync' ↔ meeting 'Ambient Morning Sync', no start time (founder's daily standup)")
    func testContainmentTitleLink() {
        // Real failure 2026-07-03: Meet imports carry no clock time, and 'sync' is a
        // stopword — Jaccard scored 0.5 → +0.3 < threshold. Full raw-token containment
        // of one title inside the other must count as near-exact.
        let links = EventMeetingLinker.links(
            events: [event("e1", "morning sync", "2026-07-02", "12:30")],
            meetings: [candidate("m1", "Ambient Morning Sync", "2026-07-02", startHM: nil)])
        #expect(links.count == 1)
        #expect(links.first?.meetingID == "m1")
    }

    @Test("single-token containment is NOT enough (generic words must not link alone)")
    func testSingleTokenContainmentRejected() {
        let links = EventMeetingLinker.links(
            events: [event("e1", "Sync", "2026-07-02", "12:30")],
            meetings: [candidate("m1", "Ambient Morning Sync", "2026-07-02", startHM: nil)])
        #expect(links.isEmpty)
    }

    @Test("all-stopword containment does NOT link on title alone (audit HIGH: 'weekly sync')")
    func testAllStopwordContainmentRejected() {
        // "weekly sync" ⊆ "Ambient Weekly Sync" but both shorter tokens are stopwords — with
        // no time or attendee signal this must NOT auto-link.
        let links = EventMeetingLinker.links(
            events: [event("e1", "weekly sync", "2026-07-02", "12:30")],
            meetings: [candidate("m1", "Ambient Weekly Sync", "2026-07-02", startHM: nil)])
        #expect(links.isEmpty)
    }

    @Test("containment picks the right sibling among same-day meetings")
    func testContainmentUnambiguousAmongSiblings() {
        let links = EventMeetingLinker.links(
            events: [event("e1", "morning sync", "2026-07-02", "12:30")],
            meetings: [candidate("m1", "Ambient Morning Sync", "2026-07-02", startHM: nil),
                       candidate("m2", "Ambient Engineering Standup", "2026-07-02", startHM: nil)])
        #expect(links.count == 1)
        #expect(links.first?.meetingID == "m1")
    }

    @Test("one event never links two meetings and vice versa (best pairing wins)")
    func testOneToOne() {
        let links = EventMeetingLinker.links(
            events: [event("e1", "Standup", "2026-07-01", "09:00")],
            meetings: [candidate("m1", "Standup", "2026-07-01", startHM: "09:01"),
                       candidate("m2", "Standup recording", "2026-07-01", startHM: "13:00")])
        #expect(links.count == 1)
        #expect(links.first?.meetingID == "m1")
    }
}

/// C1 — link persistence: upsert semantics, cascade, lookups.
@Suite("Event links store (C1)")
struct EventLinksStoreTests {
    @Test("upsert keeps max confidence; cascade follows the meeting; lookups work")
    func testLinkRoundTrip() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("cb-elinks-\(UUID().uuidString).sqlite").path
        let store = try Store(path: path)
        try store.saveMeeting(Meeting(id: "m1", title: "Standup", date: "2026-07-01", source: .gmeetLocal),
            chunks: [Store.ChunkInput(chunkID: "c1", meetingID: "m1", version: 0, seq: 0,
                                      speaker: "T", tStart: 0, tEnd: 1, text: "x", contentHash: "b:c1")])
        let start = Date(timeIntervalSince1970: 1_780_000_000)
        let mk = { (conf: Double) in
            EventMeetingLinker.Link(eventID: "eventKit|e1", meetingID: "m1", confidence: conf,
                                    method: "time+title", eventTitle: "Standup", eventStart: start)
        }
        try store.saveEventLinks([mk(0.9)])
        try store.saveEventLinks([mk(0.6)])                       // weaker rescore
        let byEvent = try store.eventLinks(eventIDs: ["eventKit|e1"])
        #expect(byEvent["eventKit|e1"]?.confidence == 0.9)         // max kept
        #expect(try store.eventLink(meetingID: "m1")?.eventTitle == "Standup")
        #expect(try store.linkedMeetingIDs() == ["m1"])
        try store.deleteMeeting(id: "m1")
        #expect(try store.eventLinks(eventIDs: ["eventKit|e1"]).isEmpty)   // cascade
    }
}
