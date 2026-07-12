import Testing
import Foundation
@testable import CallBrainCore

/// Calendar v3 — the detail panel's "Join call" button. Pure detection over the event's
/// url / location / notes fields (in that precedence). Known hosts only — a bare "zoom"
/// word or a random URL must never produce a Join button.
@Suite("Conference link detection (v3)")
struct ConferenceLinkTests {

    private func event(url: String? = nil, location: String? = nil,
                       notes: String? = nil) -> CalendarEvent {
        CalendarEvent(stableID: "e1", sourceKind: .eventKit, calendarName: "Work",
                      title: "Sync", start: Date(timeIntervalSince1970: 1_780_000_000),
                      end: Date(timeIntervalSince1970: 1_780_003_600),
                      attendees: [], isAllDay: false,
                      location: location, notes: notes, url: url)
    }

    @Test("zoom link in the url field")
    func testZoomURL() {
        let got = ConferenceLink.detect(in: event(url: "https://us02web.zoom.us/j/123456?pwd=abc"))
        #expect(got?.absoluteString == "https://us02web.zoom.us/j/123456?pwd=abc")
    }

    @Test("google meet link in the location field")
    func testMeetLocation() {
        let got = ConferenceLink.detect(in: event(location: "https://meet.google.com/abc-defg-hij"))
        #expect(got?.host == "meet.google.com")
    }

    @Test("teams link embedded inside notes prose")
    func testTeamsInNotes() {
        let notes = "Agenda:\n1. Numbers\nJoin here: https://teams.microsoft.com/l/meetup-join/19%3ameeting_x — see you"
        let got = ConferenceLink.detect(in: event(notes: notes))
        #expect(got?.host == "teams.microsoft.com")
    }

    @Test("webex link detected")
    func testWebex() {
        let got = ConferenceLink.detect(in: event(notes: "https://company.webex.com/meet/alex"))
        #expect(got?.host == "company.webex.com")
    }

    @Test("the word zoom without a URL is not a link")
    func testNoFalsePositiveWord() {
        #expect(ConferenceLink.detect(in: event(location: "Zoom (link to follow)")) == nil)
    }

    @Test("a non-conference URL is not a Join link")
    func testNoFalsePositiveURL() {
        #expect(ConferenceLink.detect(in: event(url: "https://example.com/agenda",
                                                notes: "https://docs.google.com/doc/1")) == nil)
    }

    @Test("url field wins over notes when both have conference links")
    func testPrecedence() {
        let got = ConferenceLink.detect(in: event(url: "https://zoom.us/j/111",
                                                  notes: "https://meet.google.com/xyz"))
        #expect(got?.host == "zoom.us")
    }

    @Test("lookalike host does not match (notzoom.us / zoom.us.evil.com)")
    func testHostSuffixStrict() {
        #expect(ConferenceLink.detect(in: event(url: "https://notzoom.us/j/1")) == nil)
        #expect(ConferenceLink.detect(in: event(url: "https://zoom.us.evil.com/j/1")) == nil)
    }

    @Test("plain http is never a Join link (audit LOW: untrusted calendar text)")
    func testHTTPSOnly() {
        #expect(ConferenceLink.detect(in: event(url: "http://zoom.us/j/123")) == nil)
    }
}
