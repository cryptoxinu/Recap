import Foundation
import GRDB

/// Calendar v4 — persisted AI prep briefs (v15). A brief is cached per (event, template) with
/// the source hash it was built from; reads return nil when the hash no longer matches so the
/// UI regenerates against fresh call context rather than showing a stale brief.
public extension Store {

    struct PrepBrief: Sendable, Equatable {
        public let eventID: String
        public let template: String
        public let sourceHash: String
        public let briefMD: String
        public let model: String?
        public let citationsJSON: String?   // JSON array of the brief's citations
        public let generatedAt: String
    }

    func savePrep(eventID: String, template: String, sourceHash: String,
                  briefMD: String, model: String?, citationsJSON: String? = nil) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO event_prep (event_id, template, source_hash, brief_md, model, citations_json)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(event_id, template) DO UPDATE SET
                  source_hash = excluded.source_hash,
                  brief_md = excluded.brief_md,
                  model = excluded.model,
                  citations_json = excluded.citations_json,
                  generated_at = strftime('%Y-%m-%d %H:%M:%S','now')
                """, arguments: [eventID, template, sourceHash, briefMD, model, citationsJSON])
        }
    }

    /// The cached brief IF it was built from the current source hash; nil if absent or stale.
    func prep(eventID: String, template: String, sourceHash: String) throws -> PrepBrief? {
        try dbQueue.read { db in
            guard let r = try Row.fetchOne(db, sql: """
                SELECT event_id, template, source_hash, brief_md, model, citations_json, generated_at
                FROM event_prep WHERE event_id = ? AND template = ?
                """, arguments: [eventID, template]) else { return nil }
            let stored: String = r["source_hash"]
            guard stored == sourceHash else { return nil }
            return PrepBrief(eventID: r["event_id"], template: r["template"], sourceHash: stored,
                             briefMD: r["brief_md"], model: r["model"],
                             citationsJSON: r["citations_json"], generatedAt: r["generated_at"])
        }
    }

    @discardableResult
    func deletePrep(eventID: String) throws -> Int {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM event_prep WHERE event_id = ?", arguments: [eventID])
            return db.changesCount
        }
    }
}
