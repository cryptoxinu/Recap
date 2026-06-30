import Foundation
import GRDB

/// The SQLite source of truth (GRDB, WAL). Phase-1 subset of the canonical DDL (docs/ARCHITECTURE.md §8):
/// `meetings`, `transcript_chunks`, a standalone trigger-synced `chunks_fts` (FTS5/BM25), and an
/// `embeddings` registry that stores vectors as BLOBs for the V1 brute-force-cosine lane (sqlite-vec /
/// usearch graduate later, §0 D5). The vector arm is added once the embedding model is wired.
public enum StoreError: Error, Sendable, Equatable {
    case corruptEmbedding(chunkID: String)
}

public final class Store: @unchecked Sendable {
    // @unchecked: GRDB's DatabaseQueue is internally thread-safe; we hold it immutably.
    private let dbQueue: DatabaseQueue

    public init(path: String) throws {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(sql: "PRAGMA busy_timeout = 5000")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }
        dbQueue = try DatabaseQueue(path: path, configuration: config)
        try Self.migrator.migrate(dbQueue)
    }

    // MARK: - schema

    private static let migrator: DatabaseMigrator = {
        var m = DatabaseMigrator()
        m.registerMigration("v1_core") { db in
            try db.execute(sql: """
                CREATE TABLE meetings (
                  id TEXT PRIMARY KEY, title TEXT NOT NULL, date TEXT NOT NULL,
                  start_time TEXT, duration INTEGER, source TEXT NOT NULL, company TEXT,
                  content_hash TEXT,
                  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now')),
                  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now')),
                  date_epoch INTEGER GENERATED ALWAYS AS (CAST(strftime('%s', date) AS INTEGER)) STORED
                );
                """)
            try db.execute(sql: "CREATE INDEX ix_meetings_date ON meetings(date_epoch);")
            try db.execute(sql: "CREATE INDEX ix_meetings_source ON meetings(source);")

            try db.execute(sql: """
                CREATE TABLE transcript_chunks (
                  chunk_id TEXT PRIMARY KEY,
                  meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
                  version INTEGER NOT NULL DEFAULT 0, seq INTEGER NOT NULL,
                  speaker TEXT, person_id TEXT,
                  start_timestamp REAL, end_timestamp REAL,
                  text TEXT NOT NULL, token_count INTEGER, explanatory_score REAL,
                  content_hash TEXT NOT NULL,
                  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now'))
                );
                """)
            try db.execute(sql: "CREATE INDEX ix_chunks_meeting ON transcript_chunks(meeting_id, seq);")
            try db.execute(sql: "CREATE INDEX ix_chunks_speaker ON transcript_chunks(speaker);")

            // Standalone (not external-content) FTS5: stable across VACUUM + TEXT-UUID PKs (§8.1).
            try db.execute(sql: """
                CREATE VIRTUAL TABLE chunks_fts USING fts5(
                  text, chunk_id UNINDEXED, meeting_id UNINDEXED, speaker UNINDEXED,
                  tokenize='porter unicode61 remove_diacritics 2'
                );
                """)
            try db.execute(sql: """
                CREATE TRIGGER trg_chunks_fts_ai AFTER INSERT ON transcript_chunks BEGIN
                  INSERT INTO chunks_fts(rowid, text, chunk_id, meeting_id, speaker)
                  VALUES (new.rowid, new.text, new.chunk_id, new.meeting_id, new.speaker);
                END;
                """)
            try db.execute(sql: """
                CREATE TRIGGER trg_chunks_fts_ad AFTER DELETE ON transcript_chunks BEGIN
                  DELETE FROM chunks_fts WHERE rowid = old.rowid;
                END;
                """)
            try db.execute(sql: """
                CREATE TRIGGER trg_chunks_fts_au AFTER UPDATE ON transcript_chunks BEGIN
                  DELETE FROM chunks_fts WHERE rowid = old.rowid;
                  INSERT INTO chunks_fts(rowid, text, chunk_id, meeting_id, speaker)
                  VALUES (new.rowid, new.text, new.chunk_id, new.meeting_id, new.speaker);
                END;
                """)

            try db.execute(sql: """
                CREATE TABLE embeddings (
                  chunk_id TEXT PRIMARY KEY REFERENCES transcript_chunks(chunk_id) ON DELETE CASCADE,
                  space TEXT NOT NULL, dim INTEGER NOT NULL, model_id TEXT NOT NULL,
                  vector BLOB NOT NULL, content_hash TEXT NOT NULL
                );
                """)
        }
        m.registerMigration("v2_utterances") { db in
            // Individual speaker turns (the readable, Fireflies-style transcript unit) — persisted
            // alongside the packed retrieval chunks so the Transcript Viewer renders turn-by-turn.
            try db.execute(sql: """
                CREATE TABLE utterances (
                  utterance_id TEXT PRIMARY KEY,
                  meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
                  version INTEGER NOT NULL DEFAULT 0, seq INTEGER NOT NULL,
                  speaker TEXT, person_id TEXT,
                  speaker_confidence REAL, is_inferred_speaker INTEGER NOT NULL DEFAULT 0,
                  start_timestamp REAL, end_timestamp REAL, ts_confidence TEXT,
                  text TEXT NOT NULL
                );
                """)
            try db.execute(sql: "CREATE INDEX ix_utt_meeting ON utterances(meeting_id, seq);")
        }
        m.registerMigration("v3_import_jobs") { db in
            // Durable import queue (Phase 2): a long archive backfill survives relaunch/crash, and the
            // Import Queue UI shows pending/done/failed/needs-review. No FK to meetings — a job can fail
            // before any meeting exists, and a meeting deletion shouldn't erase the import audit trail.
            try db.execute(sql: """
                CREATE TABLE import_jobs (
                  id TEXT PRIMARY KEY,
                  source_name TEXT NOT NULL,
                  state TEXT NOT NULL,
                  format TEXT,
                  used_ai INTEGER NOT NULL DEFAULT 0,
                  meeting_id TEXT,
                  title TEXT,
                  chunk_count INTEGER NOT NULL DEFAULT 0,
                  message TEXT,
                  created_at REAL NOT NULL
                );
                """)
            try db.execute(sql: "CREATE INDEX ix_import_jobs_created ON import_jobs(created_at DESC);")
        }
        m.registerMigration("v4_entities") { db in
            // Native-NER entities per meeting (Phase 2) → filter/search the library by person/org/place.
            try db.execute(sql: """
                CREATE TABLE meeting_entities (
                  meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
                  name TEXT NOT NULL, kind TEXT NOT NULL, count INTEGER NOT NULL DEFAULT 1,
                  name_lower TEXT NOT NULL,
                  PRIMARY KEY (meeting_id, kind, name_lower)
                );
                """)
            try db.execute(sql: "CREATE INDEX ix_entities_name ON meeting_entities(name_lower);")
            try db.execute(sql: "CREATE INDEX ix_entities_meeting ON meeting_entities(meeting_id);")
        }
        m.registerMigration("v5_import_payloads") { db in
            // Persist the job's input so a queued/interrupted import survives relaunch (Codex audit HIGH:
            // the "durable queue" must actually be durable). file → absolute path; paste → the text.
            try db.execute(sql: "ALTER TABLE import_jobs ADD COLUMN payload_kind TEXT;")
            try db.execute(sql: "ALTER TABLE import_jobs ADD COLUMN payload TEXT;")
        }
        m.registerMigration("v6_tasks") { db in
            // Action items surfaced from meetings (Phase 4) → a standing "what do I owe" view.
            try db.execute(sql: """
                CREATE TABLE tasks (
                  id TEXT PRIMARY KEY,
                  meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
                  owner TEXT, text TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'open',
                  source_chunk_id TEXT, start_timestamp REAL,
                  dedupe_key TEXT NOT NULL, created_at REAL NOT NULL,
                  UNIQUE(meeting_id, dedupe_key)
                );
                """)
            try db.execute(sql: "CREATE INDEX ix_tasks_status ON tasks(status);")
            try db.execute(sql: "CREATE INDEX ix_tasks_meeting ON tasks(meeting_id);")
        }
        m.registerMigration("v7_conversations") { db in
            // Durable chat sessions (Phase 4.5) → the "Recents" rail. Messages cascade-delete with their
            // conversation; a meeting_id (nullable) scopes a per-meeting AskFred thread.
            try db.execute(sql: """
                CREATE TABLE conversations (
                  id TEXT PRIMARY KEY, title TEXT NOT NULL, meeting_id TEXT,
                  created_at REAL NOT NULL, updated_at REAL NOT NULL
                );
                """)
            try db.execute(sql: "CREATE INDEX ix_conv_updated ON conversations(updated_at DESC);")
            try db.execute(sql: "CREATE INDEX ix_conv_meeting ON conversations(meeting_id);")
            try db.execute(sql: """
                CREATE TABLE messages (
                  id TEXT PRIMARY KEY,
                  conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
                  role TEXT NOT NULL, text TEXT NOT NULL, citations_json TEXT, created_at REAL NOT NULL
                );
                """)
            try db.execute(sql: "CREATE INDEX ix_msg_conv ON messages(conversation_id, created_at);")
        }
        m.registerMigration("v8_meeting_intelligence") { db in
            // Purge any legacy ORPHANED rows (left by an old non-cascading delete) so the migrator's
            // foreign-key check can't refuse to open the database (founder bug 2026-06-30). Runtime deletes
            // cascade (FKs are ON); this only cleans pre-existing rot. Order matters — clean each table
            // before the ones that reference IT (chunks → embeddings; conversations → messages).
            for child in ["utterances", "transcript_chunks", "tasks", "meeting_entities"] {
                try db.execute(sql: "DELETE FROM \(child) WHERE meeting_id NOT IN (SELECT id FROM meetings)")
            }
            try db.execute(sql: "DELETE FROM embeddings WHERE chunk_id NOT IN (SELECT chunk_id FROM transcript_chunks)")
            try db.execute(sql: "DELETE FROM conversations WHERE meeting_id IS NOT NULL AND meeting_id NOT IN (SELECT id FROM meetings)")
            try db.execute(sql: "DELETE FROM messages WHERE conversation_id NOT IN (SELECT id FROM conversations)")
            // AI-generated "proper" title + a one-line intelligence summary, shown under the call name.
            try db.execute(sql: "ALTER TABLE meetings ADD COLUMN ai_title TEXT;")
            try db.execute(sql: "ALTER TABLE meetings ADD COLUMN ai_summary TEXT;")
        }
        return m
    }()

    // MARK: - write

    /// A chunk row ready to persist (the ingest layer assembles these from a ParsedTranscript + chunks).
    public struct ChunkInput: Sendable, Equatable {
        public let chunkID: String
        public let meetingID: String
        public let version: Int
        public let seq: Int
        public let speaker: String?
        public let personID: String?
        public let tStart: Double?
        public let tEnd: Double?
        public let text: String
        public let tokenCount: Int?
        public let explanatoryScore: Double?
        public let contentHash: String

        public init(chunkID: String, meetingID: String, version: Int, seq: Int, speaker: String?,
                    personID: String? = nil, tStart: Double?, tEnd: Double?, text: String,
                    tokenCount: Int? = nil, explanatoryScore: Double? = nil, contentHash: String) {
            self.chunkID = chunkID; self.meetingID = meetingID; self.version = version; self.seq = seq
            self.speaker = speaker; self.personID = personID; self.tStart = tStart; self.tEnd = tEnd
            self.text = text; self.tokenCount = tokenCount; self.explanatoryScore = explanatoryScore
            self.contentHash = contentHash
        }
    }

    /// An embedding ready to persist atomically alongside its chunk.
    public struct EmbeddingInput: Sendable, Equatable {
        public let chunkID: String
        public let space: String
        public let dim: Int
        public let modelID: String
        public let vector: [Float]
        public let contentHash: String
        public init(chunkID: String, space: String, dim: Int, modelID: String,
                    vector: [Float], contentHash: String) {
            self.chunkID = chunkID; self.space = space; self.dim = dim
            self.modelID = modelID; self.vector = vector; self.contentHash = contentHash
        }
    }

    /// One speaker turn to persist (the readable transcript unit).
    public struct UtteranceInput: Sendable, Equatable {
        public let id: String
        public let meetingID: String
        public let version: Int
        public let seq: Int
        public let speaker: String?
        public let personID: String?
        public let speakerConfidence: Double?
        public let isInferredSpeaker: Bool
        public let tStart: Double?
        public let tEnd: Double?
        public let tsConfidence: String?
        public let text: String
        public init(id: String, meetingID: String, version: Int, seq: Int, speaker: String?,
                    personID: String? = nil, speakerConfidence: Double? = nil, isInferredSpeaker: Bool = false,
                    tStart: Double?, tEnd: Double?, tsConfidence: String?, text: String) {
            self.id = id; self.meetingID = meetingID; self.version = version; self.seq = seq
            self.speaker = speaker; self.personID = personID; self.speakerConfidence = speakerConfidence
            self.isInferredSpeaker = isInferredSpeaker; self.tStart = tStart; self.tEnd = tEnd
            self.tsConfidence = tsConfidence; self.text = text
        }
    }

    /// One extracted entity to persist with its meeting.
    public struct EntityInput: Sendable, Equatable {
        public let name: String; public let kind: String; public let count: Int
        public init(name: String, kind: String, count: Int) { self.name = name; self.kind = kind; self.count = count }
    }

    /// One action item to persist with its meeting (deduped per meeting via `dedupeKey`).
    public struct TaskInput: Sendable, Equatable {
        public let id: String; public let owner: String?; public let text: String
        public let sourceChunkID: String?; public let tStart: Double?; public let dedupeKey: String
        public init(id: String, owner: String?, text: String, sourceChunkID: String? = nil,
                    tStart: Double? = nil, dedupeKey: String) {
            self.id = id; self.owner = owner; self.text = text
            self.sourceChunkID = sourceChunkID; self.tStart = tStart; self.dedupeKey = dedupeKey
        }
    }

    /// Persist a meeting, its chunks, AND their embeddings in ONE transaction (Codex audit fix:
    /// ingest must be atomic so a failure can't leave a searchable, partially-embedded meeting).
    /// FTS rows are maintained by triggers.
    public func saveMeeting(_ m: Meeting, chunks: [ChunkInput], embeddings: [EmbeddingInput] = [],
                            utterances: [UtteranceInput] = [], entities: [EntityInput] = [],
                            tasks: [TaskInput] = []) throws {
        try dbQueue.write { db in
            // UPSERT that UPDATEs in place on id conflict — NOT INSERT OR REPLACE, which DELETEs the
            // parent row and cascade-wipes its tasks (incl. user-toggled done status), chunks, etc.
            // (Codex P4 gate HIGH). Children are maintained explicitly below.
            try db.execute(sql: """
                INSERT INTO meetings (id, title, date, start_time, duration, source, company, content_hash, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, strftime('%Y-%m-%d %H:%M:%S','now'))
                ON CONFLICT(id) DO UPDATE SET
                  title=excluded.title, date=excluded.date, start_time=excluded.start_time,
                  duration=excluded.duration, source=excluded.source, company=excluded.company,
                  content_hash=excluded.content_hash, updated_at=excluded.updated_at
                """, arguments: [m.id, m.title, m.date, m.startedAt.map(Self.iso),
                                 m.durationSeconds, m.source.rawValue, m.company, m.contentFingerprint])
            // Re-save replaces DERIVED data (chunks → cascades embeddings/FTS; utterances; entities) so no
            // stale rows linger — but NOT tasks, whose open/done status is user state (preserved via the
            // INSERT OR IGNORE below). On a normal fresh-id ingest these deletes match nothing (no-op).
            try db.execute(sql: "DELETE FROM transcript_chunks WHERE meeting_id = ?", arguments: [m.id])
            try db.execute(sql: "DELETE FROM utterances WHERE meeting_id = ?", arguments: [m.id])
            try db.execute(sql: "DELETE FROM meeting_entities WHERE meeting_id = ?", arguments: [m.id])
            for c in chunks {
                try db.execute(sql: """
                    INSERT OR REPLACE INTO transcript_chunks
                    (chunk_id, meeting_id, version, seq, speaker, person_id, start_timestamp, end_timestamp, text, token_count, explanatory_score, content_hash)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [c.chunkID, c.meetingID, c.version, c.seq, c.speaker, c.personID,
                                     c.tStart, c.tEnd, c.text, c.tokenCount, c.explanatoryScore, c.contentHash])
            }
            for e in embeddings {
                try db.execute(sql: """
                    INSERT OR REPLACE INTO embeddings (chunk_id, space, dim, model_id, vector, content_hash)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """, arguments: [e.chunkID, e.space, e.dim, e.modelID, VectorMath.encode(e.vector), e.contentHash])
            }
            for u in utterances {   // after the meeting row exists (FK)
                try db.execute(sql: """
                    INSERT OR REPLACE INTO utterances
                    (utterance_id, meeting_id, version, seq, speaker, person_id, speaker_confidence,
                     is_inferred_speaker, start_timestamp, end_timestamp, ts_confidence, text)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [u.id, u.meetingID, u.version, u.seq, u.speaker, u.personID,
                                     u.speakerConfidence, u.isInferredSpeaker ? 1 : 0,
                                     u.tStart, u.tEnd, u.tsConfidence, u.text])
            }
            for e in entities {
                try db.execute(sql: """
                    INSERT OR REPLACE INTO meeting_entities (meeting_id, name, kind, count, name_lower)
                    VALUES (?, ?, ?, ?, ?)
                    """, arguments: [m.id, e.name, e.kind, e.count, e.name.lowercased()])
            }
            for t in tasks {
                // INSERT OR IGNORE on the (meeting_id, dedupe_key) UNIQUE: re-ingest doesn't duplicate
                // a task or clobber its done/open status the user may have already toggled.
                try db.execute(sql: """
                    INSERT OR IGNORE INTO tasks
                    (id, meeting_id, owner, text, status, source_chunk_id, start_timestamp, dedupe_key, created_at)
                    VALUES (?, ?, ?, ?, 'open', ?, ?, ?, strftime('%s','now'))
                    """, arguments: [t.id, m.id, t.owner, t.text, t.sourceChunkID, t.tStart, t.dedupeKey])
            }
        }
    }

    // MARK: - tasks (action items)

    private static func decodeTask(_ r: Row) -> ActionItem {
        ActionItem(id: r["id"], meetingID: r["meeting_id"], owner: r["owner"], text: r["text"],
                   status: ActionItem.Status(rawValue: r["status"]) ?? .open,
                   sourceChunkID: r["source_chunk_id"], tStart: r["start_timestamp"],
                   createdAt: r["created_at"] ?? 0)
    }

    /// All tasks (joined with their meeting title/date for display), newest meeting first.
    public struct TaskRow: Sendable, Equatable, Identifiable {
        public let item: ActionItem
        public let meetingTitle: String
        public let meetingDate: String
        public var id: String { item.id }
    }

    public func tasks(status: ActionItem.Status? = nil, limit: Int = 500) throws -> [TaskRow] {
        try dbQueue.read { db in
            var sql = """
                SELECT t.*, m.title AS m_title, m.date AS m_date FROM tasks t
                JOIN meetings m ON m.id = t.meeting_id
                """
            var args: [(any DatabaseValueConvertible)?] = []
            if let status { sql += " WHERE t.status = ?"; args.append(status.rawValue) }
            sql += " ORDER BY m.date_epoch DESC, t.created_at DESC LIMIT ?"
            args.append(limit)
            return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args)).map {
                TaskRow(item: Self.decodeTask($0), meetingTitle: $0["m_title"], meetingDate: $0["m_date"])
            }
        }
    }

    public func tasks(meetingID: String) throws -> [ActionItem] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM tasks WHERE meeting_id = ? ORDER BY created_at",
                             arguments: [meetingID]).map(Self.decodeTask)
        }
    }

    public func setTaskStatus(id: String, _ status: ActionItem.Status) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE tasks SET status = ? WHERE id = ?", arguments: [status.rawValue, id])
        }
    }

    /// Reword / re-attribute a task (AI task reconciliation).
    public func updateTaskText(id: String, text: String, owner: String?) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE tasks SET text = ?, owner = ? WHERE id = ?", arguments: [text, owner, id])
        }
    }

    /// Add a task the AI reconciliation surfaced from a call (attributed to that meeting; FK-checked by the
    /// caller). `INSERT OR IGNORE` on the (meeting_id, dedupe_key) UNIQUE avoids re-adding the same one.
    @discardableResult
    public func addReconciledTask(meetingID: String, owner: String?, text: String) throws -> Bool {
        let id = "task_" + UUID().uuidString
        let key = "ai:" + text.lowercased().trimmingCharacters(in: .whitespaces).prefix(120)
        return try dbQueue.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO tasks (id, meeting_id, owner, text, status, dedupe_key, created_at)
                VALUES (?, ?, ?, ?, 'open', ?, strftime('%s','now'))
                """, arguments: [id, meetingID, owner, text, String(key)])
            return db.changesCount > 0
        }
    }

    public func openTaskCount() throws -> Int {
        try dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tasks WHERE status='open'") ?? 0 }
    }

    // MARK: - entities (native NER)

    public func entities(meetingID: String, limit: Int = 40) throws -> [Entity] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT name, kind, count FROM meeting_entities
                WHERE meeting_id = ? ORDER BY count DESC, name ASC LIMIT ?
                """, arguments: [meetingID, limit]).compactMap { r in
                    guard let k = EntityKind(rawValue: r["kind"]) else { return nil }
                    return Entity(name: r["name"], kind: k, count: r["count"] ?? 1)
                }
        }
    }

    /// Meetings that mention an entity (case-insensitive, substring) — cross-meeting entity search.
    public func meetingsMentioning(_ name: String, limit: Int = 100) throws -> [MeetingRow] {
        let needle = name.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return [] }
        // Escape LIKE wildcards so a name containing % or _ isn't treated as a pattern (SME audit L3).
        let escaped = needle.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
        return try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT DISTINCT m.id, m.title, m.date, m.source FROM meetings m
                JOIN meeting_entities e ON e.meeting_id = m.id
                WHERE e.name_lower LIKE ? ESCAPE '\\' ORDER BY m.date_epoch DESC LIMIT ?
                """, arguments: ["%\(escaped)%", limit]).map {
                    MeetingRow(id: $0["id"], title: $0["title"], date: $0["date"], source: $0["source"])
                }
        }
    }

    /// Meeting metadata + person-entity sets for the near-duplicate scan (Phase 6).
    public func meetingMetas(limit: Int = 1000) throws -> [MeetingMeta] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT id, title, date, source FROM meetings ORDER BY date_epoch DESC LIMIT ?",
                                        arguments: [limit])
            return try rows.map { r in
                let id: String = r["id"]
                let people = try String.fetchSet(db, sql:
                    "SELECT name_lower FROM meeting_entities WHERE meeting_id = ? AND kind = 'person'",
                    arguments: [id])
                return MeetingMeta(id: id, title: r["title"], date: r["date"], source: r["source"], people: people)
            }
        }
    }

    /// Fully delete a meeting and everything that could still hold its content (Codex P6 gate HIGH: the
    /// "transcript removed" promise must be true). Cascades chunks/embeddings/utterances/entities/tasks;
    /// deletes the meeting's own AskFred conversations (→ their messages); and SCRUBS stored citation
    /// excerpts referencing this meeting from any remaining (global) chat message.
    public func deleteMeeting(id: String) throws {
        try dbQueue.write { db in
            // 1) The meeting's own chats (meeting-scoped) → cascade their messages.
            try db.execute(sql: "DELETE FROM conversations WHERE meeting_id = ?", arguments: [id])
            // 2) Scrub citation snippets referencing this meeting from remaining messages.
            let rows = try Row.fetchAll(db, sql:
                "SELECT id, citations_json FROM messages WHERE citations_json LIKE ?",
                arguments: ["%\(id)%"])
            for r in rows {
                guard let json = r["citations_json"] as String?, let data = json.data(using: .utf8),
                      let cites = try? JSONDecoder().decode([StoredCitation].self, from: data) else { continue }
                let kept = cites.filter { $0.meetingID != id }
                guard kept.count != cites.count else { continue }
                let newJSON = (try? JSONEncoder().encode(kept)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
                try db.execute(sql: "UPDATE messages SET citations_json = ? WHERE id = ?",
                               arguments: [newJSON, r["id"] as String])
            }
            // 3) The meeting itself → cascade chunks/embeddings/utterances/entities/tasks.
            try db.execute(sql: "DELETE FROM meetings WHERE id = ?", arguments: [id])
        }
    }

    /// Top entities across the whole library (for an overview / filter chips).
    public func topEntities(kind: EntityKind? = nil, limit: Int = 30) throws -> [Entity] {
        try dbQueue.read { db in
            // MAX(name) gives a deterministic display casing across launches (SME audit L2 — a bare
            // `name` over a GROUP BY name_lower returns an arbitrary member, flip-flopping the chip text).
            var sql = """
                SELECT MAX(name) AS name, kind, SUM(count) AS total FROM meeting_entities
                """
            var args: [(any DatabaseValueConvertible)?] = []
            if let kind { sql += " WHERE kind = ?"; args.append(kind.rawValue) }
            sql += " GROUP BY kind, name_lower ORDER BY total DESC, name ASC LIMIT ?"
            args.append(limit)
            return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args)).compactMap { r in
                guard let k = EntityKind(rawValue: r["kind"]) else { return nil }
                return Entity(name: r["name"], kind: k, count: r["total"] ?? 1)
            }
        }
    }

    // MARK: - keyword search (FTS5 / BM25)

    public struct ChunkHit: Sendable, Equatable {
        public let chunkID: String
        public let meetingID: String
        public let speaker: String?
        public let text: String
        public let bm25: Double          // SQLite FTS5 bm25(): lower = better
    }

    /// Keyword/catalogue search over chunk text. `query` is an FTS5 MATCH expression (terms).
    /// `candidateChunkIDs` scopes the search IN SQL **before** LIMIT (Codex audit fix: scoping after a
    /// global LIMIT under-recalls). nil = whole corpus; [] = nothing.
    public func keywordSearch(_ query: String, limit: Int = 20,
                              candidateChunkIDs: [String]? = nil) throws -> [ChunkHit] {
        if let ids = candidateChunkIDs, ids.isEmpty { return [] }
        let terms = Self.sanitizeFTS(query)
        guard !terms.isEmpty else { return [] }
        return try dbQueue.read { db in
            var sql = """
                SELECT f.chunk_id AS chunk_id, f.meeting_id AS meeting_id, f.speaker AS speaker,
                       c.text AS text, bm25(chunks_fts) AS score
                FROM chunks_fts f
                JOIN transcript_chunks c ON c.chunk_id = f.chunk_id
                WHERE chunks_fts MATCH ?
                """
            var args: [(any DatabaseValueConvertible)?] = [terms]
            if let ids = candidateChunkIDs {
                sql += " AND f.chunk_id IN (\(ids.map { _ in "?" }.joined(separator: ",")))"
                args.append(contentsOf: ids)
            }
            sql += " ORDER BY score LIMIT ?"
            args.append(limit)
            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            return rows.map { r in
                ChunkHit(chunkID: r["chunk_id"], meetingID: r["meeting_id"],
                         speaker: r["speaker"], text: r["text"], bm25: r["score"] ?? 0)
            }
        }
    }

    // MARK: - vector lane (embeddings as BLOBs; V1 brute-force cosine, §0 D5/D6)

    public func saveEmbedding(chunkID: String, space: String, dim: Int, modelID: String,
                              vector: [Float], contentHash: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO embeddings (chunk_id, space, dim, model_id, vector, content_hash)
                VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [chunkID, space, dim, modelID, VectorMath.encode(vector), contentHash])
        }
    }

    /// All stored vectors for an embedding space, optionally restricted to a candidate `chunkIDs` set
    /// (the D6 selectivity-routed path: pre-filter in SQL, then exact brute-force over the subset).
    public func vectors(space: String, chunkIDs: [String]? = nil) throws -> [(id: String, vector: [Float])] {
        // Semantics (Codex audit fix): nil = whole space; [] = NO candidates (an empty hard-filter
        // result must not fall through to "all vectors" and leak out-of-scope evidence).
        if let ids = chunkIDs, ids.isEmpty { return [] }
        return try dbQueue.read { db in
            let rows: [Row]
            if let ids = chunkIDs {        // non-empty (guarded above)
                let placeholders = ids.map { _ in "?" }.joined(separator: ",")
                rows = try Row.fetchAll(db, sql:
                    "SELECT chunk_id, dim, vector FROM embeddings WHERE space = ? AND chunk_id IN (\(placeholders))",
                    arguments: StatementArguments([space] + ids))
            } else {
                rows = try Row.fetchAll(db, sql:
                    "SELECT chunk_id, dim, vector FROM embeddings WHERE space = ?", arguments: [space])
            }
            // A corrupt blob is a data-integrity error → surface it (never silently drop an in-scope chunk).
            return try rows.map { r in
                let dim: Int = r["dim"]
                let blob: Data = r["vector"]
                guard let v = VectorMath.decode(blob, dim: dim) else {
                    throw StoreError.corruptEmbedding(chunkID: r["chunk_id"])
                }
                return (id: r["chunk_id"], vector: v)
            }
        }
    }

    public func embeddingCount(space: String) throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM embeddings WHERE space = ?", arguments: [space]) ?? 0
        }
    }

    public struct MeetingRow: Sendable, Equatable, Identifiable {
        public let id: String
        public let title: String
        public let date: String
        public let source: String
        public var aiTitle: String? = nil
        public var aiSummary: String? = nil
        /// The proper AI title if we have one, else the original (filename-derived) title.
        public var displayTitle: String { (aiTitle?.isEmpty == false) ? aiTitle! : title }
        static func from(_ r: Row) -> MeetingRow {
            MeetingRow(id: r["id"], title: r["title"], date: r["date"], source: r["source"],
                       aiTitle: r["ai_title"], aiSummary: r["ai_summary"])
        }
    }

    public func recentMeetings(limit: Int = 200) throws -> [MeetingRow] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, title, date, source, ai_title, ai_summary FROM meetings
                ORDER BY date_epoch DESC, created_at DESC LIMIT ?
                """, arguments: [limit]).map(MeetingRow.from)
        }
    }

    /// Persist the AI-generated title + one-line summary for a call (meeting-title intelligence).
    public func setMeetingIntelligence(id: String, aiTitle: String?, aiSummary: String?) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE meetings SET ai_title = ?, ai_summary = ?, updated_at = strftime('%Y-%m-%d %H:%M:%S','now') WHERE id = ?",
                           arguments: [aiTitle, aiSummary, id])
        }
    }

    public struct TranscriptRow: Sendable, Equatable, Identifiable {
        public let id: String          // chunk_id
        public let speaker: String?
        public let tStart: Double?
        public let text: String
    }

    /// Ordered transcript chunks for a meeting (for the Transcript Viewer).
    public func transcript(meetingID: String) throws -> [TranscriptRow] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT chunk_id, speaker, start_timestamp, text FROM transcript_chunks
                WHERE meeting_id = ? ORDER BY seq
                """, arguments: [meetingID]).map {
                    TranscriptRow(id: $0["chunk_id"], speaker: $0["speaker"],
                                  tStart: $0["start_timestamp"], text: $0["text"])
                }
        }
    }

    public struct UtteranceRow: Sendable, Equatable, Identifiable {
        public let id: String
        public let speaker: String?
        public let tStart: Double?
        public let isInferred: Bool
        public let text: String
    }

    /// Ordered speaker turns for a meeting (the readable transcript). Falls back to chunks if a meeting
    /// was ingested before utterances were persisted.
    public func utterances(meetingID: String) throws -> [UtteranceRow] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT utterance_id, speaker, start_timestamp, is_inferred_speaker, text FROM utterances
                WHERE meeting_id = ? ORDER BY seq
                """, arguments: [meetingID]).map { row -> UtteranceRow in
                    let inferred: Int = row["is_inferred_speaker"] ?? 0
                    return UtteranceRow(id: row["utterance_id"], speaker: row["speaker"],
                                        tStart: row["start_timestamp"], isInferred: inferred != 0,
                                        text: row["text"])
                }
        }
    }

    public func meeting(id: String) throws -> MeetingRow? {
        try dbQueue.read { db in
            try Row.fetchOne(db, sql: "SELECT id, title, date, source, ai_title, ai_summary FROM meetings WHERE id = ?", arguments: [id])
                .map(MeetingRow.from)
        }
    }

    public func meetingCount() throws -> Int {
        try dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM meetings") ?? 0 }
    }

    /// Chunk IDs for a single meeting — the candidate set for meeting-scoped AskFred.
    public func chunkIDs(meetingID: String) throws -> [String] {
        try dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT chunk_id FROM transcript_chunks WHERE meeting_id = ? ORDER BY seq",
                                arguments: [meetingID])
        }
    }

    /// Chunk IDs whose meeting's date is in [fromYMD, toYMDExclusive) — the hard date-gating candidate
    /// set (Phase 4). `meetings.date` is "YYYY-MM-DD", so an ISO string compare is the correct ordering.
    public func chunkIDs(fromYMD: String, toYMDExclusive: String) throws -> [String] {
        try dbQueue.read { db in
            try String.fetchAll(db, sql: """
                SELECT c.chunk_id FROM transcript_chunks c
                JOIN meetings m ON m.id = c.meeting_id
                WHERE m.date >= ? AND m.date < ?
                """, arguments: [fromYMD, toYMDExclusive])
        }
    }

    /// Meetings whose date is in [fromYMD, toYMDExclusive) — for date-scoped lists / "this week".
    public func meetings(fromYMD: String, toYMDExclusive: String, limit: Int = 500) throws -> [MeetingRow] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, title, date, source FROM meetings
                WHERE date >= ? AND date < ? ORDER BY date_epoch DESC, created_at DESC LIMIT ?
                """, arguments: [fromYMD, toYMDExclusive, limit]).map {
                    MeetingRow(id: $0["id"], title: $0["title"], date: $0["date"], source: $0["source"])
                }
        }
    }

    /// Idempotency tier-1: an already-ingested meeting with this exact content fingerprint, if any
    /// (so re-dropping the same export is a no-op instead of a duplicate). Returns id + chunk count.
    public func existingMeeting(contentHash: String) throws -> (id: String, chunks: Int)? {
        try dbQueue.read { db in
            guard let id = try String.fetchOne(db,
                sql: "SELECT id FROM meetings WHERE content_hash = ? LIMIT 1", arguments: [contentHash])
            else { return nil }
            let n = try Int.fetchOne(db,
                sql: "SELECT COUNT(*) FROM transcript_chunks WHERE meeting_id = ?", arguments: [id]) ?? 0
            return (id: id, chunks: n)
        }
    }
    public func chunkCount() throws -> Int {
        try dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transcript_chunks") ?? 0 }
    }

    /// Hydrate chunks by id (e.g. vector-only hits that didn't come through the FTS lane). bm25 = 0.
    public func chunks(ids: [String]) throws -> [ChunkHit] {
        guard !ids.isEmpty else { return [] }
        return try dbQueue.read { db in
            let placeholders = ids.map { _ in "?" }.joined(separator: ",")
            let rows = try Row.fetchAll(db, sql:
                "SELECT chunk_id, meeting_id, speaker, text FROM transcript_chunks WHERE chunk_id IN (\(placeholders))",
                arguments: StatementArguments(ids))
            return rows.map { r in
                ChunkHit(chunkID: r["chunk_id"], meetingID: r["meeting_id"],
                         speaker: r["speaker"], text: r["text"], bm25: 0)
            }
        }
    }

    // MARK: - import jobs (durable queue)

    public func upsertImportJob(_ j: ImportJob) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO import_jobs
                (id, source_name, state, format, used_ai, meeting_id, title, chunk_count, message, created_at,
                 payload_kind, payload)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [j.id, j.sourceName, j.state.rawValue, j.format, j.usedAI ? 1 : 0,
                                 j.meetingID, j.title, j.chunkCount, j.message, j.createdAt,
                                 j.payloadKind?.rawValue, j.payload])
        }
    }

    private static func decodeJob(_ r: Row) -> ImportJob {
        let used: Int = r["used_ai"] ?? 0
        return ImportJob(
            id: r["id"], sourceName: r["source_name"],
            state: ImportJob.State(rawValue: r["state"]) ?? .failed,
            format: r["format"], usedAI: used != 0, meetingID: r["meeting_id"],
            title: r["title"], chunkCount: r["chunk_count"] ?? 0,
            message: r["message"], createdAt: r["created_at"] ?? 0,
            payloadKind: (r["payload_kind"] as String?).flatMap(ImportJob.PayloadKind.init),
            payload: r["payload"])
    }

    public func importJobs(limit: Int = 100) throws -> [ImportJob] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM import_jobs ORDER BY created_at DESC LIMIT ?
                """, arguments: [limit]).map(Self.decodeJob)
        }
    }

    /// ALL still-pending jobs (queued/running) oldest-first — the processing queue (NOT display-limited,
    /// Codex audit HIGH: a 150-file drop must not strand the oldest 50 behind a 100-row display cap).
    public func pendingImportJobs() throws -> [ImportJob] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM import_jobs WHERE state IN ('queued','running') ORDER BY created_at ASC
                """).map(Self.decodeJob)
        }
    }

    public func deleteImportJob(id: String) throws {
        try dbQueue.write { db in try db.execute(sql: "DELETE FROM import_jobs WHERE id = ?", arguments: [id]) }
    }

    /// Clear FINISHED jobs (done + failed) only; keep queued/running AND `needsReview` (Codex audit LOW:
    /// clearing must not silently drop the AI-import review queue before the user confirms it).
    @discardableResult
    public func clearFinishedImportJobs() throws -> Int {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM import_jobs WHERE state IN ('done','failed')")
            return db.changesCount
        }
    }

    // MARK: - conversations (durable chat sessions)

    public func upsertConversation(_ c: Conversation) throws {
        try dbQueue.write { db in
            // In-place UPSERT — NOT INSERT OR REPLACE, which would DELETE the row and cascade-wipe its
            // messages on a retitle/rescope (Codex P4.5 gate MED).
            try db.execute(sql: """
                INSERT INTO conversations (id, title, meeting_id, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                  title=excluded.title, meeting_id=excluded.meeting_id, updated_at=excluded.updated_at
                """, arguments: [c.id, c.title, c.meetingID, c.createdAt, c.updatedAt])
        }
    }

    /// Conversations newest-activity first. `meetingID` filters to a meeting's threads; pass nil for the
    /// global Ask "Recents", or omit (`.some(nil)` vs absent) — here absent = all, nil-string-filter via
    /// the dedicated method below.
    public func conversations(limit: Int = 100) throws -> [Conversation] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM conversations ORDER BY updated_at DESC LIMIT ?",
                             arguments: [limit]).map(Self.decodeConversation)
        }
    }

    /// Global (non-meeting) conversations only — the Ask-AI Recents rail.
    public func globalConversations(limit: Int = 100) throws -> [Conversation] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql:
                "SELECT * FROM conversations WHERE meeting_id IS NULL ORDER BY updated_at DESC LIMIT ?",
                arguments: [limit]).map(Self.decodeConversation)
        }
    }

    public func conversations(meetingID: String, limit: Int = 50) throws -> [Conversation] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql:
                "SELECT * FROM conversations WHERE meeting_id = ? ORDER BY updated_at DESC LIMIT ?",
                arguments: [meetingID, limit]).map(Self.decodeConversation)
        }
    }

    public func conversation(id: String) throws -> Conversation? {
        try dbQueue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM conversations WHERE id = ?", arguments: [id])
                .map(Self.decodeConversation)
        }
    }

    public func renameConversation(id: String, title: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE conversations SET title = ? WHERE id = ?", arguments: [title, id])
        }
    }

    public func deleteConversation(id: String) throws {
        try dbQueue.write { db in try db.execute(sql: "DELETE FROM conversations WHERE id = ?", arguments: [id]) }
    }

    /// Append a message and bump its conversation's `updated_at` in ONE transaction (Recents ordering
    /// stays consistent with the latest turn).
    public func appendMessage(_ msg: Message) throws {
        let json = (try? JSONEncoder().encode(msg.citations)).flatMap { String(data: $0, encoding: .utf8) }
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO messages (id, conversation_id, role, text, citations_json, created_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [msg.id, msg.conversationID, msg.role.rawValue, msg.text, json, msg.createdAt])
            try db.execute(sql: "UPDATE conversations SET updated_at = ? WHERE id = ?",
                           arguments: [msg.createdAt, msg.conversationID])
        }
    }

    public func messages(conversationID: String) throws -> [Message] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql:
                "SELECT * FROM messages WHERE conversation_id = ? ORDER BY created_at", arguments: [conversationID])
                .map(Self.decodeMessage)
        }
    }

    private static func decodeConversation(_ r: Row) -> Conversation {
        Conversation(id: r["id"], title: r["title"], meetingID: r["meeting_id"],
                     createdAt: r["created_at"] ?? 0, updatedAt: r["updated_at"] ?? 0)
    }
    private static func decodeMessage(_ r: Row) -> Message {
        let cites: [StoredCitation] = (r["citations_json"] as String?)
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode([StoredCitation].self, from: $0) } ?? []
        return Message(id: r["id"], conversationID: r["conversation_id"],
                       role: Message.Role(rawValue: r["role"]) ?? .user, text: r["text"],
                       citations: cites, createdAt: r["created_at"] ?? 0)
    }

    // MARK: - backup / restore (Phase 8)

    /// Write a clean, consistent snapshot of the whole database to `url` (a `.cbk` file) via SQLite
    /// `VACUUM INTO` — safe to run on the live DB (it's a transactional copy, no WAL fragments).
    public func backup(to url: URL) throws {
        let path = url.path.replacingOccurrences(of: "'", with: "''")
        try? FileManager.default.removeItem(at: url)   // VACUUM INTO fails if the target exists
        // VACUUM can't run inside a transaction → writeWithoutTransaction.
        try dbQueue.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM INTO '\(path)'")
        }
    }

    /// Validate a `.cbk` is a real CallBrain backup before a restore overwrites the user's data. Opens
    /// **read-only** so validation never mutates the backup or spills `-wal`/`-shm` next to it.
    public static func isValidBackup(at url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        var config = Configuration()
        config.readonly = true
        guard let q = try? DatabaseQueue(path: url.path, configuration: config) else { return false }
        return ((try? q.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM sqlite_master WHERE type='table' AND name IN ('meetings','transcript_chunks')") ?? 0
        }) ?? 0) == 2
    }

    // MARK: - helpers

    private static func iso(_ d: Date) -> String { ISO8601DateFormatter().string(from: d) }

    /// Turn a user phrase into a safe FTS5 MATCH expression: quote each alphanumeric token so
    /// punctuation/operators in raw input can't break the query (e.g. `"render" "pricing"`).
    static func sanitizeFTS(_ s: String) -> String {
        let tokens = s.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init)
        return tokens.map { "\"\($0)\"" }.joined(separator: " ")
    }
}
