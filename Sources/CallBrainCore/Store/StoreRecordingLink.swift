import Foundation
import GRDB

/// A live recording's durable hand-off to its eventual meeting (v18). When a recording stops we
/// don't yet know the meeting ID — the WAV still has to be transcribed + ingested, which can take
/// minutes (first-run model download) or outlive the app session. We persist the intent keyed by
/// the WAV path (== `import_jobs.payload`); a reconciler resolves it once the job lands a meeting.
public struct PendingRecordingLink: Sendable, Equatable {
    public let filePath: String
    public let eventID: String?
    public let notes: String?
    /// The wall-clock time the recording began — applied to the resulting meeting's `start_time`
    /// (nil for older rows written before v20, or non-recording hand-offs).
    public let startedAt: Date?
    public init(filePath: String, eventID: String?, notes: String?, startedAt: Date? = nil) {
        self.filePath = filePath; self.eventID = eventID; self.notes = notes; self.startedAt = startedAt
    }
}

public extension Store {

    /// Record (or replace) the intent to attach notes / a calendar link / a real start time to
    /// whatever meeting the recording at `filePath` becomes. No-op-safe to call again with the same path.
    func savePendingRecordingLink(filePath: String, eventID: String?, notes: String?,
                                  startedAt: Date? = nil) throws {
        let trimmedNotes = notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        let e = (eventID?.isEmpty ?? true) ? nil : eventID
        let n = (trimmedNotes?.isEmpty ?? true) ? nil : trimmedNotes
        let s = startedAt.map { Self.linkISO().string(from: $0) }
        try dbQueue.write { db in
            // COALESCE, don't clobber: a second call for the same path (e.g. link-then-notes, or a
            // retry passing nil for a field it doesn't have) must NOT erase a value already stored.
            // `INSERT OR REPLACE` rewrote the whole row and wiped the missing field (audit E MED).
            try db.execute(sql: """
                INSERT INTO pending_recording_link (file_path, event_id, notes, created_at, started_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(file_path) DO UPDATE SET
                  event_id   = COALESCE(excluded.event_id, pending_recording_link.event_id),
                  notes      = COALESCE(excluded.notes, pending_recording_link.notes),
                  started_at = COALESCE(excluded.started_at, pending_recording_link.started_at)
                """, arguments: [filePath, e, n, Date().timeIntervalSince1970, s])
        }
    }

    func pendingRecordingLinks() throws -> [PendingRecordingLink] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql:
                "SELECT file_path, event_id, notes, started_at FROM pending_recording_link ORDER BY created_at ASC")
                .map { r in
                    let startedAt = (r["started_at"] as String?).flatMap { Self.linkISO().date(from: $0) }
                    return PendingRecordingLink(filePath: r["file_path"], eventID: r["event_id"],
                                                notes: r["notes"], startedAt: startedAt)
                }
        }
    }

    func deletePendingRecordingLink(filePath: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM pending_recording_link WHERE file_path = ?", arguments: [filePath])
        }
    }

    /// Stamp a meeting's `start_time` with the recording's real start — ONLY if it's still NULL, so a
    /// value already carried by a parsed transcript is never overwritten and a repeat reconcile is a
    /// no-op. Same ISO-8601 encoding `saveMeeting` uses, so the linker reads both identically.
    func setMeetingStartTimeIfUnset(meetingID: String, startedAt: Date) throws {
        try dbQueue.write { db in
            try db.execute(sql:
                "UPDATE meetings SET start_time = ? WHERE id = ? AND start_time IS NULL",
                arguments: [Self.linkISO().string(from: startedAt), meetingID])
        }
    }

    /// A fresh ISO-8601 formatter matching `Store.saveMeeting`'s `start_time` encoding so linker reads
    /// line up. Built per-call (not a shared static) because `ISO8601DateFormatter` isn't `Sendable`.
    private static func linkISO() -> ISO8601DateFormatter { ISO8601DateFormatter() }

    /// The meeting the NEWEST import job for this exact file path produced, if it has one yet.
    /// Returns `nil` until that newest job commits a meeting — so on a same-path re-import we bind
    /// to the fresh recording, never an older resolved job (P2b audit MED: filtering NOT NULL
    /// before ordering let a stale older meeting win over a newer still-ingesting one).
    func meetingIDForImportPayload(_ path: String) throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(db, sql: """
                SELECT meeting_id FROM import_jobs
                WHERE payload = ?
                ORDER BY created_at DESC LIMIT 1
                """, arguments: [path])
        }
    }
}
