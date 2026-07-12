import Foundation
import GRDB

/// Live-recording notes (v17) — the founder's own notes typed while recording a meeting,
/// kept separate from the AI `call_summary` so a summary regeneration never clobbers them.
public extension Store {

    /// Append a note to a meeting (blank-line separated); no-op on empty. Idempotent: if the exact
    /// note block is already present it does nothing, so a retried reconcile (append succeeded but
    /// the pending-row delete failed) never double-writes the founder's notes (P1 audit MED).
    func appendMeetingNote(meetingID: String, note: String) throws {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try dbQueue.write { db in
            let existing = try String.fetchOne(db, sql: "SELECT user_notes FROM meetings WHERE id = ?",
                                               arguments: [meetingID]) ?? ""
            // Already contains this exact note as a whole line-block → leave it be.
            let blocks = existing.components(separatedBy: "\n\n")
            guard !blocks.contains(trimmed) else { return }
            let merged = existing.isEmpty ? trimmed : "\(existing)\n\n\(trimmed)"
            // Bump updated_at like every other content writer (setSummaryAndTasks etc.) so a notes edit
            // is a truthful dirty-marker — the corpus exporter (Part B) re-exports a call when its notes
            // change. Without this, edited notes never propagate to the exported files.
            try db.execute(sql: """
                UPDATE meetings SET user_notes = ?, updated_at = strftime('%Y-%m-%d %H:%M:%S','now')
                WHERE id = ?
                """,
                           arguments: [merged, meetingID])
        }
    }

    func userNotes(meetingID: String) throws -> String? {
        try dbQueue.read { db in
            let s = try String.fetchOne(db, sql: "SELECT user_notes FROM meetings WHERE id = ?",
                                        arguments: [meetingID])
            return (s?.isEmpty ?? true) ? nil : s
        }
    }
}
