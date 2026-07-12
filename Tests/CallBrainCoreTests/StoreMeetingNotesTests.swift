import Testing
import Foundation
import GRDB
@testable import CallBrainCore

/// Live-recording notes (v17) — the founder's own notes. B0: appending a note must bump
/// `meetings.updated_at` so the corpus exporter (Part B) treats an edited note as a real change
/// and re-exports the call. Also locks the existing idempotent-re-append behaviour.
@Suite("Meeting notes (updated_at dirty-marker)")
struct StoreMeetingNotesTests {

    private func freshStore() throws -> Store {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("cb-notes-\(UUID().uuidString).sqlite").path
        return try Store(path: path)
    }

    @Test("appendMeetingNote saves the note AND bumps updated_at")
    func appendBumpsUpdatedAt() throws {
        let store = try freshStore()
        try store.saveMeeting(Meeting(id: "m1", title: "Sync", date: "2026-07-09", source: .fireflies),
                              chunks: [])

        // Force a known-old updated_at so the assertion is second-precision-proof.
        try store.dbQueue.write { db in
            try db.execute(sql: "UPDATE meetings SET updated_at = '2000-01-01 00:00:00' WHERE id = 'm1'")
        }

        try store.appendMeetingNote(meetingID: "m1", note: "watch the cloud-cost line")

        #expect(try store.userNotes(meetingID: "m1") == "watch the cloud-cost line")
        let updatedAt = try store.dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT updated_at FROM meetings WHERE id = 'm1'")
        }
        #expect(updatedAt != "2000-01-01 00:00:00") // bumped by the note edit
        #expect(updatedAt != nil)
    }

    @Test("re-appending the same note is idempotent and does not duplicate")
    func idempotentReAppend() throws {
        let store = try freshStore()
        try store.saveMeeting(Meeting(id: "m2", title: "Sync", date: "2026-07-09", source: .fireflies),
                              chunks: [])
        try store.appendMeetingNote(meetingID: "m2", note: "note A")
        try store.appendMeetingNote(meetingID: "m2", note: "note A")
        #expect(try store.userNotes(meetingID: "m2") == "note A")
    }
}
