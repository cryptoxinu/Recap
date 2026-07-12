import Testing
import Foundation
@testable import CallBrainCore

@Suite("Recording title + calendar auto-link (Phase 2)")
struct RecordingLinkTests {

    // ── title stamp stripping ──
    @Test("stripRecordingStamp removes the ' — yyyy-MM-dd HHmm' suffix (+ counter), leaves clean titles")
    func stripsStamp() {
        #expect(IngestEngine.stripRecordingStamp("Partner sync — 2026-07-11 1430") == "Partner sync")
        #expect(IngestEngine.stripRecordingStamp("Partner sync — 2026-07-11 1430 (2)") == "Partner sync")
        #expect(IngestEngine.stripRecordingStamp("Recording · Jul 11, 2-05 PM — 2026-07-11 1430") == "Recording · Jul 11, 2-05 PM")
        #expect(IngestEngine.stripRecordingStamp("Q3 Board Review") == "Q3 Board Review")         // no stamp → unchanged
        #expect(IngestEngine.stripRecordingStamp("Drive Export 2026-07-11") == "Drive Export 2026-07-11") // date but not the stamp shape
        #expect(!IngestEngine.stripRecordingStamp("— 2026-07-11 1430").isEmpty)                    // never returns empty
    }

    // ── event-happening-now picker ──
    private func ev(_ id: String, _ start: Date, _ end: Date, allDay: Bool = false) -> CalendarEvent {
        CalendarEvent(stableID: id, sourceKind: .eventKit, calendarName: "W", title: "Event \(id)",
                      start: start, end: end, attendees: [], isAllDay: allDay)
    }

    @Test("happeningNow picks the timed event overlapping now; grace covers early/late; all-day excluded")
    func happeningNow() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let inProgress = ev("a", now.addingTimeInterval(-600), now.addingTimeInterval(600))  // started 10m ago
        let earlyJoin  = ev("b", now.addingTimeInterval(180), now.addingTimeInterval(1800))  // starts in 3m (grace)
        let over       = ev("c", now.addingTimeInterval(-7200), now.addingTimeInterval(-3600)) // ended an hour ago
        let allDay     = ev("d", now.addingTimeInterval(-600), now.addingTimeInterval(600), allDay: true)

        #expect(EventMeetingLinker.happeningNow([over, inProgress], now: now)?.stableID == "a")
        #expect(EventMeetingLinker.happeningNow([earlyJoin], now: now)?.stableID == "b")   // within 5-min grace
        #expect(EventMeetingLinker.happeningNow([over], now: now) == nil)                  // nothing overlaps
        #expect(EventMeetingLinker.happeningNow([allDay], now: now) == nil)                // all-day never matches
        // An IN-PROGRESS call beats a not-yet-started grace-window one (audit HIGH: don't grab the
        // call starting in 3 min over the one you're actually in).
        #expect(EventMeetingLinker.happeningNow([earlyJoin, inProgress], now: now)?.stableID == "a")
        // Two in-progress → nearest start wins.
        let alsoInProgress = ev("e", now.addingTimeInterval(-1800), now.addingTimeInterval(1800))  // started 30m ago
        #expect(EventMeetingLinker.happeningNow([alsoInProgress, inProgress], now: now)?.stableID == "a")
    }
}
