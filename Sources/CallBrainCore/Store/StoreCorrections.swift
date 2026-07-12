import Foundation
import GRDB

// Retroactive vocabulary correction of ALREADY-STORED transcripts (#42 / TC5). Display + at-ingest
// correction only fix what you see + new calls; this catches up the back catalogue so KEYWORD and
// SEMANTIC search over old calls find the corrected terms too.
extension Store {
    /// Re-apply the current corrections to stored `utterances` + `transcript_chunks`, KEYSET-PAGED so a
    /// huge library never loads wholesale into memory (audit MED). Each page is its own transaction that
    /// updates the changed text (+ chunk `content_hash`, + bumped `version`) AND enqueues the changed
    /// chunks for re-embedding IN THE SAME TRANSACTION — so a corrected chunk can never end up with FTS
    /// fixed but its embedding never scheduled (audit HIGH). `chunks_fts` re-syncs via its AFTER-UPDATE
    /// trigger, so keyword search corrects immediately. Only CHANGED rows are written (idempotent — safe
    /// to re-run, and a partial sweep just finishes on the next run). Returns the changed counts.
    ///
    /// - Parameters:
    ///   - meetingIDs: nil → the whole library; otherwise only those meetings (incremental path).
    ///   - space: the embedding space to enqueue changed chunks under (the changed vectors are stale).
    @discardableResult
    public func recorrectTranscripts(meetingIDs: [String]?,
                                     applicator: CorrectionDictionary.Applicator,
                                     space: String,
                                     batchSize: Int = 500)
        throws -> (utterances: Int, chunks: Int) {
        let uChanged = try pageAndFix(table: "utterances", idColumn: "utterance_id",
                                      meetingIDs: meetingIDs, batchSize: batchSize, applicator: applicator) { db, id, fixed in
            try db.execute(sql: "UPDATE utterances SET text = ?, version = version + 1 WHERE utterance_id = ?",
                           arguments: [fixed, id])
        }
        let cChanged = try pageAndFix(table: "transcript_chunks", idColumn: "chunk_id",
                                      meetingIDs: meetingIDs, batchSize: batchSize, applicator: applicator) { db, id, fixed in
            let hash = "sha256:" + IngestEngine.sha256(fixed)
            try db.execute(sql: """
                UPDATE transcript_chunks SET text = ?, content_hash = ?, version = version + 1 WHERE chunk_id = ?
                """, arguments: [fixed, hash, id])
            // Same transaction: schedule the re-embed so text/FTS and the embed-IOU commit together.
            try db.execute(sql: "INSERT OR IGNORE INTO pending_embeddings (chunk_id, space) VALUES (?, ?)",
                           arguments: [id, space])
        }
        return (uChanged, cChanged)
    }

    /// Keyset-page over `table` ordered by its TEXT-UUID primary key, applying `applicator` to each row's
    /// `text` and invoking `onChanged` for rows that actually change — each PAGE in its own write
    /// transaction (bounded memory). Only `text`/`content_hash`/`version` are written, never the id or the
    /// scoping/ordering columns, so keyset pagination stays stable across batches. Returns changed count.
    private func pageAndFix(table: String, idColumn: String, meetingIDs: [String]?, batchSize: Int,
                            applicator: CorrectionDictionary.Applicator,
                            onChanged: (Database, _ id: String, _ fixed: String) throws -> Void) throws -> Int {
        var changed = 0
        var cursor = ""   // keyset marker: last id seen ("" sorts before any UUID)
        while true {
            let sawRows = try dbQueue.write { db -> Bool in
                var sql = "SELECT \(idColumn) AS id, text FROM \(table) WHERE \(idColumn) > ?"
                var args: [any DatabaseValueConvertible] = [cursor]
                if let ids = meetingIDs {
                    sql += " AND meeting_id IN (SELECT value FROM json_each(?))"
                    args.append(Self.jsonArray(ids))
                }
                sql += " ORDER BY \(idColumn) LIMIT \(batchSize)"
                let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
                guard !rows.isEmpty else { return false }
                for row in rows {
                    let id: String = row["id"], text: String = row["text"]
                    cursor = id
                    let fixed = applicator.apply(to: text)
                    if fixed != text { try onChanged(db, id, fixed); changed += 1 }
                }
                return true
            }
            if !sawRows { break }
        }
        return changed
    }

    /// Distinct meeting IDs whose transcript contains `term` (via FTS), so an incremental re-correction
    /// can target ONLY the calls a newly-added correction could touch — fast regardless of library size.
    /// Returns [] on an empty/unmatchable term. (Porter stemming may occasionally miss an exact token; the
    /// full-library sweep is the authoritative catch-all.)
    public func meetingIDsContaining(_ term: String) throws -> [String] {
        let match = Self.sanitizeFTS(term)
        guard !match.isEmpty else { return [] }
        return try dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT DISTINCT meeting_id FROM chunks_fts WHERE chunks_fts MATCH ?",
                                arguments: [match])
        }
    }
}
