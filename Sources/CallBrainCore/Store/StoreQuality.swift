import Foundation
import GRDB

/// Batched quality signals for the "Clean up duplicates with AI" resolver (2026-07-09). One read,
/// a few grouped counts joined in Swift — never an N+1 per meeting. Off-main callers only.
extension Store {

    /// Quality signals for the given meetings, keyed by id. Missing ids simply don't appear.
    public func meetingQualitySignals(ids: [String]) throws -> [String: DuplicateResolver.MeetingQuality] {
        guard !ids.isEmpty else { return [:] }
        let json = Self.jsonArray(ids)
        return try dbQueue.read { db in
            // Core rows — title/ai_title/source/date + whether a full summary exists.
            let metaRows = try Row.fetchAll(db, sql: """
                SELECT id, title, ai_title, source, date, call_summary
                FROM meetings WHERE id IN (SELECT value FROM json_each(?))
                """, arguments: [json])

            func counts(_ table: String) throws -> [String: Int] {
                var out: [String: Int] = [:]
                let rows = try Row.fetchAll(db, sql: """
                    SELECT meeting_id AS mid, COUNT(*) AS n FROM \(table)
                    WHERE meeting_id IN (SELECT value FROM json_each(?)) GROUP BY meeting_id
                    """, arguments: [json])
                for r in rows { out[r["mid"]] = r["n"] }
                return out
            }
            let chunkCounts = try counts("transcript_chunks")
            let taskCounts = try counts("tasks")

            var durations: [String: Double] = [:]
            let durRows = try Row.fetchAll(db, sql: """
                SELECT meeting_id AS mid, MAX(end_timestamp) AS dur FROM utterances
                WHERE meeting_id IN (SELECT value FROM json_each(?)) GROUP BY meeting_id
                """, arguments: [json])
            for r in durRows { durations[r["mid"]] = r["dur"] }

            var out: [String: DuplicateResolver.MeetingQuality] = [:]
            for r in metaRows {
                let id: String = r["id"]
                let rawTitle: String = r["title"]
                let aiTitle: String? = r["ai_title"]
                let hasAITitle = (aiTitle?.isEmpty == false) && aiTitle != rawTitle
                let displayTitle = hasAITitle ? aiTitle! : rawTitle
                let summary: String? = r["call_summary"]
                out[id] = DuplicateResolver.MeetingQuality(
                    id: id,
                    title: displayTitle,
                    source: r["source"],
                    date: r["date"],
                    chunkCount: chunkCounts[id] ?? 0,
                    taskCount: taskCounts[id] ?? 0,
                    hasFullSummary: (summary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false),
                    hasAITitle: hasAITitle,
                    durationSec: durations[id] ?? 0)
            }
            return out
        }
    }
}
