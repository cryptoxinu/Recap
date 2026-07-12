import Foundation
import GRDB

/// Perfection plan Task 7.1a — the ⌘K palette backend. ONE read transaction fans a query across
/// meetings (title/ai_title), moments (chunk FTS via the fixed keyword lane), tasks, and chat
/// threads, each group capped for a scannable palette.
extension Store {

    public struct UniversalResults: Sendable, Equatable {
        public var meetings: [MeetingRow] = []
        public var moments: [ChunkHit] = []
        public var tasks: [TaskRow] = []
        public var chats: [Conversation] = []
        public var isEmpty: Bool { meetings.isEmpty && moments.isEmpty && tasks.isEmpty && chats.isEmpty }
        public init() {}
    }

    /// convID → first line of its NEWEST assistant answer (Recents rail snippets, Task 7.5).
    public func conversationSnippets(ids: [String]) throws -> [String: String] {
        guard !ids.isEmpty else { return [:] }
        return try dbQueue.read { db in
            var out: [String: String] = [:]
            let rows = try Row.fetchAll(db, sql: """
                SELECT m.conversation_id AS cid, m.text AS t FROM messages m
                JOIN (SELECT conversation_id, MAX(created_at) AS mx FROM messages
                      WHERE role = 'assistant' AND (provider IS NULL OR provider != ?)
                      GROUP BY conversation_id) last
                  ON last.conversation_id = m.conversation_id AND last.mx = m.created_at
                WHERE m.role = 'assistant'
                  AND (m.provider IS NULL OR m.provider != ?)
                  AND m.conversation_id IN (SELECT value FROM json_each(?))
                ORDER BY m.id
                """, arguments: [Self.failedTurnProviderMarker, Self.failedTurnProviderMarker,
                                  Self.jsonArray(ids)])
            for r in rows { out[r["cid"]] = r["t"] }   // ties resolve to max id (deterministic)
            return out
        }
    }

    /// True if a conversation has at least one assistant answer (failed-only threads aren't kept).
    public func conversationHasAnswer(id: String) throws -> Bool {
        try dbQueue.read { db in
            (try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM messages
                WHERE conversation_id = ? AND role = 'assistant'
                  AND (provider IS NULL OR provider != ?)
                """, arguments: [id, Self.failedTurnProviderMarker]) ?? 0) > 0
        }
    }

    public func searchEverything(_ raw: String,
                                 meetingCap: Int = 5, momentCap: Int = 8,
                                 taskCap: Int = 5, chatCap: Int = 5) throws -> UniversalResults {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return UniversalResults() }
        // Moments ride the FTS lane (sanitized like every Ask query) — do it first, OUTSIDE the
        // LIKE transaction, via the existing API so behavior matches Ask exactly.
        let moments = try keywordSearch(q, limit: momentCap)
        let escaped = q.replacingOccurrences(of: "\\", with: "\\\\")   // user backslashes FIRST (gate LOW)
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        let like = "%\(escaped)%"

        return try dbQueue.read { db in
            var r = UniversalResults()
            r.moments = moments
            r.meetings = try Row.fetchAll(db, sql: """
                SELECT \(Self.meetingCols) FROM meetings
                WHERE title LIKE ? ESCAPE '\\' OR ai_title LIKE ? ESCAPE '\\'
                ORDER BY date_epoch DESC LIMIT ?
                """, arguments: [like, like, meetingCap]).map(MeetingRow.from)
            r.tasks = try Row.fetchAll(db, sql: """
                SELECT t.*, m.title AS m_title, COALESCE(m.ai_title, m.title) AS m_display, m.date AS m_date
                FROM tasks t JOIN meetings m ON m.id = t.meeting_id
                WHERE t.text LIKE ? ESCAPE '\\' OR t.owner LIKE ? ESCAPE '\\'
                ORDER BY t.status = 'done', t.created_at DESC LIMIT ?
                """, arguments: [like, like, taskCap]).map {
                TaskRow(item: Self.decodeTask($0), meetingTitle: $0["m_display"], meetingDate: $0["m_date"])
            }
            r.chats = try Row.fetchAll(db, sql: """
                SELECT DISTINCT c.* FROM conversations c
                LEFT JOIN messages m ON m.conversation_id = c.id
                WHERE c.title LIKE ? ESCAPE '\\' OR m.text LIKE ? ESCAPE '\\'
                ORDER BY c.updated_at DESC LIMIT ?
                """, arguments: [like, like, chatCap]).map { row in
                Conversation(id: row["id"], title: row["title"], meetingID: row["meeting_id"],
                             createdAt: row["created_at"], updatedAt: row["updated_at"])
            }
            return r
        }
    }
}
