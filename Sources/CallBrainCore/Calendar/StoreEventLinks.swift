import Foundation
import GRDB

/// Calendar initiative C1 — persistence for event↔meeting links.
extension Store {

    public struct EventLink: Sendable, Equatable {
        public let eventID: String
        public let meetingID: String
        public let confidence: Double
        public let method: String
        public let eventTitle: String
        public let eventStart: Date
    }

    /// Upsert links (re-running the linker refreshes snapshots; confidence keeps the max so a
    /// weaker rescore never downgrades an established link).
    public func saveEventLinks(_ links: [EventMeetingLinker.Link]) throws {
        guard !links.isEmpty else { return }
        try dbQueue.write { db in
            for l in links {
                // Policy (gate HIGH): same meeting → refresh snapshot, keep MAX confidence.
                // A DIFFERENT meeting replaces the link only with STRICTLY higher confidence,
                // and carries its OWN confidence (never inherits the old one).
                try db.execute(sql: """
                    INSERT INTO event_links (event_id, meeting_id, confidence, method, event_title, event_start)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(event_id) DO UPDATE SET
                      meeting_id = CASE WHEN excluded.meeting_id = event_links.meeting_id
                                          OR excluded.confidence > event_links.confidence
                                        THEN excluded.meeting_id ELSE event_links.meeting_id END,
                      confidence = CASE WHEN excluded.meeting_id = event_links.meeting_id
                                        THEN MAX(event_links.confidence, excluded.confidence)
                                        WHEN excluded.confidence > event_links.confidence
                                        THEN excluded.confidence ELSE event_links.confidence END,
                      method = CASE WHEN excluded.meeting_id = event_links.meeting_id
                                      OR excluded.confidence > event_links.confidence
                                    THEN excluded.method ELSE event_links.method END,
                      event_title = excluded.event_title,
                      event_start = excluded.event_start
                    """, arguments: [l.eventID, l.meetingID, l.confidence, l.method,
                                     l.eventTitle, l.eventStart.timeIntervalSince1970])
            }
        }
    }

    /// eventID → link, for a set of event IDs (the Calendar tab's Recorded badges).
    public func eventLinks(eventIDs: [String]) throws -> [String: EventLink] {
        guard !eventIDs.isEmpty else { return [:] }
        return try dbQueue.read { db in
            var out: [String: EventLink] = [:]
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM event_links WHERE event_id IN (SELECT value FROM json_each(?))
                """, arguments: [Self.jsonArray(eventIDs)])
            for r in rows { out[r["event_id"]] = Self.decodeLink(r) }
            return out
        }
    }

    /// The linked calendar event for one call (MeetingDetail chip).
    public func eventLink(meetingID: String) throws -> EventLink? {
        try dbQueue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM event_links WHERE meeting_id = ? ORDER BY confidence DESC LIMIT 1",
                             arguments: [meetingID]).map(Self.decodeLink)
        }
    }

    /// Meetings that already carry a link (the linker skips them — links are stable unless unlinked).
    public func linkedMeetingIDs() throws -> Set<String> {
        try dbQueue.read { db in
            Set(try String.fetchAll(db, sql: "SELECT DISTINCT meeting_id FROM event_links"))
        }
    }

    /// EventKit identifier-churn healing (gate HIGH): a link whose event_start falls INSIDE a
    /// freshly-loaded range but whose event_id is NOT among the loaded events is orphaned (the
    /// provider re-identified the event after a sync). Deleting it frees the meeting to relink
    /// against the event's new identity on the next linker pass.
    @discardableResult
    public func pruneOrphanedEventLinks(loadedEventIDs: [String], rangeStart: Date, rangeEnd: Date) throws -> Int {
        try dbQueue.write { db in
            try db.execute(sql: """
                DELETE FROM event_links
                WHERE event_start >= ? AND event_start <= ?
                  AND event_id NOT IN (SELECT value FROM json_each(?))
                """, arguments: [rangeStart.timeIntervalSince1970, rangeEnd.timeIntervalSince1970,
                                 Self.jsonArray(loadedEventIDs)])
            return db.changesCount
        }
    }

    public func deleteEventLink(eventID: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM event_links WHERE event_id = ?", arguments: [eventID])
        }
    }

    /// Everything the linker needs about the corpus, one read: id, display title, date,
    /// parsed start time, and people (entities). Skips meetings that already carry a link.
    public func meetingCandidatesForLinking() throws -> [EventMeetingLinker.MeetingCandidate] {
        let linked = try linkedMeetingIDs()
        let meetings = try recentMeetings()
        let people = try meetingPeople(ids: meetings.map(\.id), perMeeting: 8)
        let iso = ISO8601DateFormatter()
        return try dbQueue.read { db in
            var starts: [String: String] = [:]
            for r in try Row.fetchAll(db, sql: "SELECT id, start_time FROM meetings WHERE start_time IS NOT NULL") {
                starts[r["id"]] = r["start_time"]
            }
            return meetings.filter { !linked.contains($0.id) }.map { m in
                EventMeetingLinker.MeetingCandidate(
                    meetingID: m.id, title: m.displayTitle, date: m.date,
                    startedAt: starts[m.id].flatMap { iso.date(from: $0) },
                    people: people[m.id] ?? [])
            }
        }
    }

    private static func decodeLink(_ r: Row) -> EventLink {
        EventLink(eventID: r["event_id"], meetingID: r["meeting_id"],
                  confidence: r["confidence"], method: r["method"],
                  eventTitle: r["event_title"],
                  eventStart: Date(timeIntervalSince1970: r["event_start"]))
    }
}
