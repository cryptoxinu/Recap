import Foundation
import GRDB

/// Perfection plan Task 2.3 — merging the two halves of one call. ⚠ ORDER IS LOAD-BEARING
/// (judge BLOCKER): every FK in this schema is ON DELETE CASCADE, so the loser's children MUST
/// be explicitly re-pointed BEFORE its meeting row is deleted — "rely on the cascade" destroys
/// the founder's tasks, chunks, and entities. Everything happens in ONE write transaction.
extension Store {

    public struct MergeStats: Sendable, Equatable {
        public var chunksMoved = 0
        public var utterancesMoved = 0
        public var tasksMoved = 0
        public var tasksDeduped = 0
        public var entitiesMerged = 0
        public var conversationsMoved = 0
        public var citationsRewritten = 0
        public init() {}
    }

    public enum MergeError: Error, Equatable { case meetingNotFound(String) }

    /// Merge `loserID` (the gemini-notes half) into `survivorID` (the transcript half).
    /// Chunk IDs never change, so embeddings (keyed by chunk_id) and citation chunk links keep
    /// working; the v11 chunk_id-keyed FTS triggers refresh meeting_id on the UPDATE.
    @discardableResult
    public func mergeMeetings(loserID: String, survivorID: String) throws -> MergeStats {
        // A self-merge (same id) would re-point + dedupe the meeting's OWN children and then run
        // `DELETE FROM meetings WHERE id = loser`, cascading the survivor's content to oblivion —
        // a catastrophic no-op. Refuse it outright (audit E CRITICAL).
        guard loserID != survivorID else { return MergeStats() }
        vectorRevision.add(1)   // invalidate the whole-space vector cache (Task 5.2)
        return try dbQueue.write { db in
            guard let loser = try Row.fetchOne(db, sql: "SELECT * FROM meetings WHERE id = ?", arguments: [loserID])
            else { throw MergeError.meetingNotFound(loserID) }
            guard let survivor = try Row.fetchOne(db, sql: "SELECT * FROM meetings WHERE id = ?", arguments: [survivorID])
            else { throw MergeError.meetingNotFound(survivorID) }

            var stats = MergeStats()

            // 1. Retrieval chunks + transcript turns — plain re-point (no unique constraints).
            try db.execute(sql: "UPDATE transcript_chunks SET meeting_id = ? WHERE meeting_id = ?",
                           arguments: [survivorID, loserID])
            stats.chunksMoved = db.changesCount
            try db.execute(sql: "UPDATE utterances SET meeting_id = ? WHERE meeting_id = ?",
                           arguments: [survivorID, loserID])
            stats.utterancesMoved = db.changesCount

            // 2. Tasks — UNIQUE(meeting_id, dedupe_key): a task both halves extracted collides;
            //    the survivor's copy wins and the loser's duplicate is dropped (feeds Task 2.4).
            let taskRows = try Row.fetchAll(db, sql: "SELECT id, dedupe_key FROM tasks WHERE meeting_id = ?",
                                            arguments: [loserID])
            for t in taskRows {
                let loserStatus = try String.fetchOne(db, sql: "SELECT status FROM tasks WHERE id = ?",
                                                      arguments: [t["id"] as String])
                let survivorTaskStatus = try String.fetchOne(db, sql:
                    "SELECT status FROM tasks WHERE meeting_id = ? AND dedupe_key = ?",
                    arguments: [survivorID, t["dedupe_key"] as String])
                if let survivorTaskStatus {
                    // Collision: before dropping the loser's copy, a RESOLVED loser (done/dismissed)
                    // wins over a still-open survivor so a completed task doesn't resurface as open
                    // (audit E HIGH — task-merge collisions were discarding user state).
                    if survivorTaskStatus == "open", let loserStatus, loserStatus != "open" {
                        try db.execute(sql: "UPDATE tasks SET status = ? WHERE meeting_id = ? AND dedupe_key = ?",
                                       arguments: [loserStatus, survivorID, t["dedupe_key"] as String])
                    }
                    try db.execute(sql: "DELETE FROM tasks WHERE id = ?", arguments: [t["id"] as String])
                    stats.tasksDeduped += 1
                } else {
                    try db.execute(sql: "UPDATE tasks SET meeting_id = ? WHERE id = ?",
                                   arguments: [survivorID, t["id"] as String])
                    stats.tasksMoved += 1
                }
            }

            // 3. NER entities — PK (meeting_id, kind, name_lower): merge counts on collision.
            try db.execute(sql: """
                INSERT INTO meeting_entities (meeting_id, name, kind, count, name_lower)
                SELECT ?, name, kind, count, name_lower FROM meeting_entities WHERE meeting_id = ?
                ON CONFLICT(meeting_id, kind, name_lower) DO UPDATE SET count = count + excluded.count
                """, arguments: [survivorID, loserID])
            stats.entitiesMerged = db.changesCount
            try db.execute(sql: "DELETE FROM meeting_entities WHERE meeting_id = ?", arguments: [loserID])

            // 4. Per-call chat threads follow the surviving call.
            try db.execute(sql: "UPDATE conversations SET meeting_id = ? WHERE meeting_id = ?",
                           arguments: [survivorID, loserID])
            stats.conversationsMoved = db.changesCount

            // 4b. Import-queue audit rows carry a DENORMALIZED meeting_id (no FK — deliberately
            // survives meeting deletion) and the Import UI opens jobs through it (Codex phase-2
            // HIGH: un-re-pointed rows dangled at deleted gemini meetings after the 8-pair merge).
            try db.execute(sql: "UPDATE import_jobs SET meeting_id = ? WHERE meeting_id = ?",
                           arguments: [survivorID, loserID])

            // 5. Persisted chat citations — denormalized JSON, no FK: rewrite meetingIDs so old
            //    answers keep navigating (chunk IDs are unchanged by design).
            let msgs = try Row.fetchAll(db, sql:
                "SELECT id, citations_json FROM messages WHERE citations_json LIKE ?",
                arguments: ["%\(loserID)%"])
            for m in msgs {
                guard let json: String = m["citations_json"],
                      let data = json.data(using: .utf8),
                      var cites = try? JSONDecoder().decode([StoredCitation].self, from: data) else { continue }
                cites = cites.map { c in
                    c.meetingID == loserID
                        ? StoredCitation(tag: c.tag, chunkID: c.chunkID, meetingID: survivorID,
                                         speaker: c.speaker, text: c.text, tStart: c.tStart)
                        : c
                }
                if let out = try? JSONEncoder().encode(cites), let s = String(data: out, encoding: .utf8) {
                    try db.execute(sql: "UPDATE messages SET citations_json = ? WHERE id = ?",
                                   arguments: [s, m["id"] as String])
                    stats.citationsRewritten += 1
                }
            }

            // 6. The gemini half usually has the better title + Google's own notes summary —
            //    adopt them where the survivor has nothing.
            if (survivor["ai_title"] as String?)?.isEmpty != false {
                let cleanTitle = (loser["ai_title"] as String?).flatMap { $0.isEmpty ? nil : $0 }
                    ?? (loser["title"] as String? ?? "")
                if !cleanTitle.isEmpty {
                    try db.execute(sql: "UPDATE meetings SET ai_title = ? WHERE id = ?",
                                   arguments: [cleanTitle, survivorID])
                }
            }
            if (survivor["call_summary"] as String?)?.isEmpty != false,
               let notes = loser["call_summary"] as String?, !notes.isEmpty {
                try db.execute(sql: "UPDATE meetings SET call_summary = ?, summary_source = ? WHERE id = ?",
                               arguments: [notes, loser["summary_source"] as String? ?? "gemini", survivorID])
            }
            if (survivor["ai_summary"] as String?)?.isEmpty != false,
               let one = loser["ai_summary"] as String?, !one.isEmpty {
                try db.execute(sql: "UPDATE meetings SET ai_summary = ? WHERE id = ?",
                               arguments: [one, survivorID])
            }

            // 6b. Live-recording notes (v17) are the founder's OWN words — never dropped on a
            //     merge. Concatenate the loser's onto the survivor's (blank-line separated,
            //     de-duped) so a duplicate-review merge keeps both halves' notes (P1 audit MED).
            let survivorNotes = (survivor["user_notes"] as String?) ?? ""
            let loserNotes = (loser["user_notes"] as String?) ?? ""
            if !loserNotes.isEmpty {
                let existingBlocks = Set(survivorNotes.components(separatedBy: "\n\n"))
                let fresh = loserNotes.components(separatedBy: "\n\n").filter { !existingBlocks.contains($0) }
                if !fresh.isEmpty {
                    let merged = ([survivorNotes] + fresh).filter { !$0.isEmpty }.joined(separator: "\n\n")
                    try db.execute(sql: "UPDATE meetings SET user_notes = ? WHERE id = ?",
                                   arguments: [merged, survivorID])
                }
            }

            // 6c. Calendar recording links (v14) — `event_links.meeting_id` is ON DELETE CASCADE,
            //     so the loser's link would vanish with it. Re-point to the survivor first (audit
            //     E HIGH). UNIQUE(event_id) means the survivor may already own that event → keep
            //     the survivor's link and drop the loser's; otherwise move it over.
            let loserLinkEvents = try String.fetchAll(db, sql: "SELECT event_id FROM event_links WHERE meeting_id = ?",
                                                      arguments: [loserID])
            for eventID in loserLinkEvents {
                let survivorHasIt = try Bool.fetchOne(db, sql:
                    "SELECT EXISTS(SELECT 1 FROM event_links WHERE event_id = ? AND meeting_id = ?)",
                    arguments: [eventID, survivorID]) ?? false
                if survivorHasIt {
                    try db.execute(sql: "DELETE FROM event_links WHERE event_id = ? AND meeting_id = ?",
                                   arguments: [eventID, loserID])
                } else {
                    try db.execute(sql: "UPDATE event_links SET meeting_id = ? WHERE event_id = ? AND meeting_id = ?",
                                   arguments: [survivorID, eventID, loserID])
                }
            }

            // 7. ONLY NOW is the loser childless — safe to delete (nothing left to cascade).
            try db.execute(sql: "DELETE FROM meetings WHERE id = ?", arguments: [loserID])
            return stats
        }
    }
}
