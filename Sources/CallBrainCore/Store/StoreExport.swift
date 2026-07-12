import Foundation
import GRDB

/// Read-only Store APIs for the Call Corpus exporter (Part B). No migration, no writes: `MeetingRow` is
/// kept lean for hot list paths, so the exporter reads the extra frontmatter columns + the cheap
/// change-detection feed through these dedicated queries instead of widening it.
public extension Store {

    /// One row per meeting for cheap change detection — `updated_at` + `content_hash` are all the exporter
    /// needs to decide skip vs re-export, WITHOUT loading any transcript. Order is unspecified.
    struct ExportManifestRow: Sendable, Equatable {
        public let id: String
        public let updatedAt: String
        public let contentHash: String?
    }

    func exportManifest() throws -> [ExportManifestRow] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT id, updated_at, content_hash FROM meetings").map { row in
                ExportManifestRow(id: row["id"], updatedAt: row["updated_at"] ?? "",
                                  contentHash: row["content_hash"])
            }
        }
    }

    /// The frontmatter columns `MeetingRow` doesn't carry. nil when the meeting no longer exists.
    struct ExportMeta: Sendable, Equatable {
        public let startTime: String?          // ISO8601, if known
        public let durationColumn: Int?        // meetings.duration (often null; real duration = MAX utterance end)
        public let company: String?
        public let contentHash: String?
        public let updatedAt: String
        public let categoryConfidence: Double?
    }

    func exportMeta(id: String) throws -> ExportMeta? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT start_time, duration, company, content_hash, updated_at, category_confidence
                FROM meetings WHERE id = ?
                """, arguments: [id]) else { return nil }
            return ExportMeta(startTime: row["start_time"], durationColumn: row["duration"],
                              company: row["company"], contentHash: row["content_hash"],
                              updatedAt: row["updated_at"] ?? "", categoryConfidence: row["category_confidence"])
        }
    }
}
