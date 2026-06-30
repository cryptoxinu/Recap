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

    /// Persist a meeting and its chunks in one transaction (FTS rows are maintained by triggers).
    public func saveMeeting(_ m: Meeting, chunks: [ChunkInput]) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO meetings (id, title, date, start_time, duration, source, company, content_hash, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, strftime('%Y-%m-%d %H:%M:%S','now'))
                """, arguments: [m.id, m.title, m.date, m.startedAt.map(Self.iso),
                                 m.durationSeconds, m.source.rawValue, m.company, m.contentFingerprint])
            for c in chunks {
                try db.execute(sql: """
                    INSERT OR REPLACE INTO transcript_chunks
                    (chunk_id, meeting_id, version, seq, speaker, person_id, start_timestamp, end_timestamp, text, token_count, explanatory_score, content_hash)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [c.chunkID, c.meetingID, c.version, c.seq, c.speaker, c.personID,
                                     c.tStart, c.tEnd, c.text, c.tokenCount, c.explanatoryScore, c.contentHash])
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
    public func keywordSearch(_ query: String, limit: Int = 20) throws -> [ChunkHit] {
        let terms = Self.sanitizeFTS(query)
        guard !terms.isEmpty else { return [] }
        return try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT f.chunk_id AS chunk_id, f.meeting_id AS meeting_id, f.speaker AS speaker,
                       c.text AS text, bm25(chunks_fts) AS score
                FROM chunks_fts f
                JOIN transcript_chunks c ON c.chunk_id = f.chunk_id
                WHERE chunks_fts MATCH ?
                ORDER BY score
                LIMIT ?
                """, arguments: [terms, limit])
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

    public func meetingCount() throws -> Int {
        try dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM meetings") ?? 0 }
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

    // MARK: - helpers

    private static func iso(_ d: Date) -> String { ISO8601DateFormatter().string(from: d) }

    /// Turn a user phrase into a safe FTS5 MATCH expression: quote each alphanumeric token so
    /// punctuation/operators in raw input can't break the query (e.g. `"render" "pricing"`).
    static func sanitizeFTS(_ s: String) -> String {
        let tokens = s.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init)
        return tokens.map { "\"\($0)\"" }.joined(separator: " ")
    }
}
