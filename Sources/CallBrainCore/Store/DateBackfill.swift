import Foundation
import os

/// Perfection plan Task 2.2 — one-time repair of transcribed-meeting dates. Every `gmeet_local`
/// row in the production store was stamped with its IMPORT day (audit CRITICAL); the true call
/// date is trapped in the title ("morning sync - 2026-06-30 09-29 PDT - Recording-…").
///
/// DELIBERATELY a standalone plan/apply pair invoked only by `cbeval backfill-dates` — NEVER a
/// registered DatabaseMigrator migration, which would auto-run on the next app launch with no
/// dry-run or backup gate (judge MAJOR). Confident-only: a meeting changes ONLY when the Task-2.1
/// parser finds an explicit, plausible date in its original title.
public enum DateBackfill {
    static let log = Logger(subsystem: "com.callbrain", category: "date-backfill")

    public struct Change: Sendable, Equatable, Codable {
        public let meetingID: String
        public let title: String
        public let oldDate: String
        public let newDate: String
    }

    /// Read-only: list every transcribed meeting whose title carries a confident date that
    /// disagrees with its stored date.
    public static func plan(store: Store) throws -> [Change] {
        try store.transcribedMeetings().compactMap { row in
            let parsed = IngestEngine.filenameMeta(URL(fileURLWithPath: row.title)).date
            guard let newDate = parsed, newDate != row.date else { return nil }
            return Change(meetingID: row.id, title: row.title, oldDate: row.date, newDate: newDate)
        }
    }

    /// Apply reviewed changes. Idempotent: a change whose old date no longer matches the stored
    /// date (already applied, or the row moved) is skipped, never blind-written. Returns the
    /// number of rows actually updated; each update is audit-logged.
    @discardableResult
    public static func apply(store: Store, changes: [Change]) throws -> Int {
        var applied = 0
        for c in changes {
            guard let row = try store.meeting(id: c.meetingID), row.date == c.oldDate else { continue }
            try store.updateMeetingDate(id: c.meetingID, date: c.newDate)
            log.notice("date backfill: \(c.meetingID, privacy: .public) '\(c.title, privacy: .public)' \(c.oldDate, privacy: .public) → \(c.newDate, privacy: .public)")
            applied += 1
        }
        return applied
    }
}
