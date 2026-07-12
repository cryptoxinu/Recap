import Foundation
import GRDB

/// The SQLite source of truth (GRDB, WAL). Phase-1 subset of the canonical DDL (docs/ARCHITECTURE.md §8):
/// `meetings`, `transcript_chunks`, a standalone trigger-synced `chunks_fts` (FTS5/BM25), and an
/// `embeddings` registry that stores vectors as BLOBs for the V1 brute-force-cosine lane (sqlite-vec /
/// usearch graduate later, §0 D5). The vector arm is added once the embedding model is wired.
public enum StoreError: Error, Sendable, Equatable {
    case corruptEmbedding(chunkID: String)
    /// A DIFFERENT meeting already holds this content_hash — caught inside the save transaction to
    /// close the check-then-insert dedupe race (two simultaneous ingests of identical content).
    case duplicateContent(existingID: String)
}

public final class Store: @unchecked Sendable {
    // @unchecked: GRDB's DatabaseQueue is internally thread-safe; we hold it immutably.
    // internal (not private) so Store extensions can split across files (StoreMerge.swift etc.)
    // instead of growing this one god-file — never touch it from outside CallBrainCore.
    let dbQueue: DatabaseQueue
    /// Provider sentinel for persisted assistant rows that represent failed turns, not real answers.
    public static let failedTurnProviderMarker = "__callbrain_failed_turn"

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
        m.registerMigration("v9_call_summary") { db in
            // Full markdown call summary for the Summary tab (Gemini-notes calls reuse Google's notes
            // instead — no AI call). `summary_source`: "local" (on-device Ollama) | "cloud" (CLI premium)
            // | "gemini" (Google's notes) so we know where it came from.
            try db.execute(sql: "ALTER TABLE meetings ADD COLUMN call_summary TEXT;")
            try db.execute(sql: "ALTER TABLE meetings ADD COLUMN summary_source TEXT;")
        }
        m.registerMigration("v10_category") { db in
            // Which venture a call belongs to (Ambient / Further Health / Other) for tagging + filtering.
            // `category_manual` = 1 means the user set it by hand, so auto-classification won't overwrite it.
            try db.execute(sql: "ALTER TABLE meetings ADD COLUMN category TEXT;")
            try db.execute(sql: "ALTER TABLE meetings ADD COLUMN category_confidence REAL;")
            try db.execute(sql: "ALTER TABLE meetings ADD COLUMN category_manual INTEGER NOT NULL DEFAULT 0;")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS ix_meetings_category ON meetings(category);")
        }
        m.registerMigration("v11_fts_chunkid_rekey") { db in
            // Perfection plan Task 2.0: FTS sync triggers were keyed on transcript_chunks.rowid.
            // Empirically VACUUM INTO preserves these rowids today (verified 2026-07-03), but the
            // SQLite docs explicitly permit renumbering rowids of non-INTEGER-PK tables — so keying
            // on the stable chunk_id removes the whole latent class before Phase 2.3 bulk-updates
            // chunk rows during cross-source merges. Repopulates the index once (source of truth =
            // transcript_chunks), which also self-heals any store that ever did desync.
            try db.execute(sql: "DROP TRIGGER IF EXISTS trg_chunks_fts_ai;")
            try db.execute(sql: "DROP TRIGGER IF EXISTS trg_chunks_fts_ad;")
            try db.execute(sql: "DROP TRIGGER IF EXISTS trg_chunks_fts_au;")
            try db.execute(sql: """
                CREATE TRIGGER trg_chunks_fts_ai AFTER INSERT ON transcript_chunks BEGIN
                  INSERT INTO chunks_fts(text, chunk_id, meeting_id, speaker)
                  VALUES (new.text, new.chunk_id, new.meeting_id, new.speaker);
                END;
                """)
            try db.execute(sql: """
                CREATE TRIGGER trg_chunks_fts_ad AFTER DELETE ON transcript_chunks BEGIN
                  DELETE FROM chunks_fts WHERE chunk_id = old.chunk_id;
                END;
                """)
            try db.execute(sql: """
                CREATE TRIGGER trg_chunks_fts_au AFTER UPDATE ON transcript_chunks BEGIN
                  DELETE FROM chunks_fts WHERE chunk_id = old.chunk_id;
                  INSERT INTO chunks_fts(text, chunk_id, meeting_id, speaker)
                  VALUES (new.text, new.chunk_id, new.meeting_id, new.speaker);
                END;
                """)
            try db.execute(sql: "DELETE FROM chunks_fts;")
            try db.execute(sql: """
                INSERT INTO chunks_fts(text, chunk_id, meeting_id, speaker)
                SELECT text, chunk_id, meeting_id, speaker FROM transcript_chunks;
                """)
        }
        m.registerMigration("v12_message_steps_provider") { db in
            // Reasoning timeline + answering engine survive a Recents reload (perfection Task 3.1).
            try db.execute(sql: "ALTER TABLE messages ADD COLUMN steps_json TEXT;")
            try db.execute(sql: "ALTER TABLE messages ADD COLUMN provider TEXT;")
        }
        m.registerMigration("v13_pending_embeddings") { db in
            // Durable embedding IOUs (Task 5.1a): text + FTS land even with Ollama down; the
            // backfill job embeds these when the local AI returns. Cascades with its chunk.
            try db.execute(sql: """
                CREATE TABLE pending_embeddings (
                  chunk_id TEXT PRIMARY KEY REFERENCES transcript_chunks(chunk_id) ON DELETE CASCADE,
                  space TEXT NOT NULL,
                  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now'))
                );
                """)
        }
        m.registerMigration("v14_event_links") { db in
            // Calendar initiative C1: persisted event↔meeting links with a display SNAPSHOT of
            // the event (title/start), so the UI renders links even when the provider is
            // unreachable. meeting_id cascades — a deleted call drops its link.
            try db.execute(sql: """
                CREATE TABLE event_links (
                  event_id TEXT PRIMARY KEY,
                  meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
                  confidence REAL NOT NULL,
                  method TEXT NOT NULL,
                  event_title TEXT NOT NULL,
                  event_start REAL NOT NULL,
                  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now'))
                );
                """)
            try db.execute(sql: "CREATE INDEX ix_event_links_meeting ON event_links(meeting_id);")
        }
        m.registerMigration("v15_event_prep") { db in
            // Calendar v4: cached AI prep briefs, keyed by calendar event id + template.
            // `source_hash` fingerprints the contributing calls/summaries so a brief is
            // regenerated only when its inputs actually change (PrepPrompt.sourceHash).
            try db.execute(sql: """
                CREATE TABLE event_prep (
                  event_id TEXT NOT NULL,
                  template TEXT NOT NULL,
                  source_hash TEXT NOT NULL,
                  brief_md TEXT NOT NULL,
                  model TEXT,
                  generated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now')),
                  PRIMARY KEY (event_id, template)
                );
                """)
        }
        m.registerMigration("v16_event_prep_citations") { db in
            // Persist the brief's citations (JSON) so a cache hit keeps tappable [S#] chips —
            // without it, a restored brief rendered inert markers (v4-final audit MED).
            try db.execute(sql: "ALTER TABLE event_prep ADD COLUMN citations_json TEXT;")
        }
        m.registerMigration("v17_meeting_user_notes") { db in
            // The founder's own notes typed while recording a meeting (Granola-style live notes).
            try db.execute(sql: "ALTER TABLE meetings ADD COLUMN user_notes TEXT;")
        }
        m.registerMigration("v18_pending_recording_link") { db in
            // Durable hand-off from a live recording to the meeting the pipeline eventually
            // produces from its WAV. The old in-memory 60s poll lost live notes + calendar
            // links whenever transcription outran the poll or the app relaunched (P1 audit
            // HIGH). Keyed by the WAV path, which equals the import_jobs.payload — so once the
            // job lands a meeting_id, the reconciler resolves the note + event link and deletes
            // the row. `event_id`/`notes` are nullable (a link with no notes, or notes with no
            // event, are both valid).
            try db.execute(sql: """
                CREATE TABLE pending_recording_link (
                  file_path  TEXT PRIMARY KEY,
                  event_id   TEXT,
                  notes      TEXT,
                  created_at TEXT NOT NULL
                );
                """)
        }
        m.registerMigration("v19_repair_multi_owner_tasks") { db in
            // Repair tasks whose MULTI-PERSON owner list was left stuck inside the text — e.g.
            // "[Jordan Reyes, Sam Okafor, Alex] Discuss May Payouts…" — because a >40-char
            // bracket used to fail owner parsing (founder bug 2026-07-09), leaving the row UNASSIGNED
            // with the names in the text (so it wrongly showed under "For you"). Re-parse: move the
            // names to `owner`, strip the prefix from `text`, refresh `dedupe_key`. Scoped to the
            // comma-list case only (single-name brackets were always parsed at ingest), and skips any
            // row that would collide on UNIQUE(meeting_id, dedupe_key) so no data is lost.
            let rows = try Row.fetchAll(db, sql: "SELECT id, meeting_id, owner, text FROM tasks WHERE text LIKE '[%]%'")
            for r in rows {
                let text: String = r["text"]
                guard let parsed = ActionItemExtractor.ownerLine(text), parsed.owner.contains(","),
                      parsed.text != text else { continue }
                let id: String = r["id"], mid: String = r["meeting_id"]
                let currentOwner: String? = r["owner"]
                let newOwner = (currentOwner?.isEmpty == false) ? currentOwner! : parsed.owner
                let newKey = "\(newOwner.lowercased())|\(parsed.text.lowercased())"
                let clash = try Int.fetchOne(db, sql:
                    "SELECT COUNT(*) FROM tasks WHERE meeting_id = ? AND dedupe_key = ? AND id <> ?",
                    arguments: [mid, newKey, id]) ?? 0
                guard clash == 0 else { continue }
                try db.execute(sql: "UPDATE tasks SET owner = ?, text = ?, dedupe_key = ? WHERE id = ?",
                               arguments: [newOwner, parsed.text, newKey, id])
            }
        }
        m.registerMigration("v20_pending_recording_start_time") { db in
            // Carry the recording's WALL-CLOCK start time through to the meeting it becomes, so
            // `meetings.start_time` is the real time the call began instead of NULL (which pinned
            // every manual recording to midnight-of-day and killed `EventMeetingLinker`'s strongest
            // signal — start-time proximity). The reconciler applies it once the WAV lands a meeting.
            try db.execute(sql: "ALTER TABLE pending_recording_link ADD COLUMN started_at TEXT")
        }
        m.registerMigration("v21_task_completion_source") { db in
            // Record WHY/when a task was completed so a later call auto-completing a stale open task can show
            // "✓ done from ‹call›" and stay honest/reversible (Tasks-overhaul Phase 3). Nullable — a manual
            // check-off leaves them NULL; only the transcript-driven completion stamps them.
            try db.execute(sql: "ALTER TABLE tasks ADD COLUMN completed_by_meeting_id TEXT")
            try db.execute(sql: "ALTER TABLE tasks ADD COLUMN completed_at TEXT")
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
    /// `pendingEmbeddingSpace`: when set (and `embeddings` is empty — Ollama down), pending-IOU
    /// rows are written for every chunk IN THE SAME TRANSACTION (gate MED: a separate enqueue
    /// could fail after the save, leaving a meeting permanently unembedded because re-ingest
    /// dedupes on content_hash).
    public func saveMeeting(_ m: Meeting, chunks: [ChunkInput], embeddings: [EmbeddingInput] = [],
                            utterances: [UtteranceInput] = [], entities: [EntityInput] = [],
                            tasks: [TaskInput] = [], pendingEmbeddingSpace: String? = nil) throws {
        vectorRevision.add(1)   // invalidate the whole-space vector cache (Task 5.2)
        try dbQueue.write { db in
            // Close the dedupe RACE (audit D4/E MED): the caller checks `existingMeeting` on a
            // separate read, so two simultaneous ingests of identical content can both miss and
            // both insert. Re-check for a DIFFERENT meeting with this content_hash INSIDE the
            // serialized write transaction and refuse — the caller catches it and returns the twin.
            if let hash = m.contentFingerprint, !hash.isEmpty,
               let twin = try String.fetchOne(db, sql:
                "SELECT id FROM meetings WHERE content_hash = ? AND id <> ? LIMIT 1", arguments: [hash, m.id]) {
                throw StoreError.duplicateContent(existingID: twin)
            }
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
                    """, arguments: [c.chunkID, m.id, c.version, c.seq, c.speaker, c.personID,
                                     c.tStart, c.tEnd, c.text, c.tokenCount, c.explanatoryScore, c.contentHash])
                    // ^ bind the PARENT meeting id, never the child's own field — a caller that set
                    //   c.meetingID to a DIFFERENT existing meeting would pass FK checks and corrupt
                    //   that meeting's retrieval/FTS (audit E HIGH).
            }
            // Durable embedding IOUs in the SAME txn (gate MED) — AFTER the chunk inserts so the
            // pending_embeddings→transcript_chunks FK holds.
            if let space = pendingEmbeddingSpace, embeddings.isEmpty {
                for c in chunks {
                    try db.execute(sql: "INSERT OR IGNORE INTO pending_embeddings (chunk_id, space) VALUES (?, ?)",
                                   arguments: [c.chunkID, space])
                }
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
                    """, arguments: [u.id, m.id, u.version, u.seq, u.speaker, u.personID,
                                     u.speakerConfidence, u.isInferredSpeaker ? 1 : 0,
                                     u.tStart, u.tEnd, u.tsConfidence, u.text])   // parent id (audit E HIGH)
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

    static func decodeTask(_ r: Row) -> ActionItem {
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
                SELECT t.*, COALESCE(NULLIF(m.ai_title,''), m.title) AS m_display, m.date AS m_date FROM tasks t
                JOIN meetings m ON m.id = t.meeting_id
                """
            var args: [(any DatabaseValueConvertible)?] = []
            if let status { sql += " WHERE t.status = ?"; args.append(status.rawValue) }
            sql += " ORDER BY m.date_epoch DESC, t.created_at DESC LIMIT ?"
            args.append(limit)
            return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args)).map {
                TaskRow(item: Self.decodeTask($0), meetingTitle: $0["m_display"], meetingDate: $0["m_date"])
            }
        }
    }

    public func tasks(meetingID: String) throws -> [ActionItem] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM tasks WHERE meeting_id = ? ORDER BY created_at",
                             arguments: [meetingID]).map(Self.decodeTask)
        }
    }

    /// Returns true if a row actually changed (false if the task no longer exists) so callers don't show a
    /// stale optimistic UI for a task that was deleted out from under them. `completedByMeetingID` stamps
    /// the source when a call's transcript completed the task (Phase 3) — shown as "✓ done from ‹call›" and
    /// cleared if the task is later re-opened (it's no longer "done from" anything).
    @discardableResult
    public func setTaskStatus(id: String, _ status: ActionItem.Status,
                              completedByMeetingID: String? = nil) throws -> Bool {
        try dbQueue.write { db in
            if status == .done, let mid = completedByMeetingID {
                try db.execute(sql: "UPDATE tasks SET status = ?, completed_by_meeting_id = ?, completed_at = ? WHERE id = ?",
                               arguments: [status.rawValue, mid, Self.iso(Date()), id])
            } else if status == .open {
                try db.execute(sql: "UPDATE tasks SET status = ?, completed_by_meeting_id = NULL, completed_at = NULL WHERE id = ?",
                               arguments: [status.rawValue, id])
            } else {   // manual done (no source) — flip status, leave any existing stamp untouched
                try db.execute(sql: "UPDATE tasks SET status = ? WHERE id = ?", arguments: [status.rawValue, id])
            }
            return db.changesCount > 0
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
    /// Returns the NEW task id when a row was actually inserted (nil if the dedupe UNIQUE swallowed it) —
    /// so a caller (Tidy) can record it for a clean undo.
    @discardableResult
    public func addReconciledTask(meetingID: String, owner: String?, text: String) throws -> String? {
        let id = "task_" + UUID().uuidString
        // Dedupe on owner + full text (SME LOW — two distinct tasks with different owners or the same first
        // 120 chars must not collide on the (meeting_id, dedupe_key) UNIQUE).
        let key = "ai:\(owner?.lowercased() ?? "")|\(text.lowercased().trimmingCharacters(in: .whitespaces))"
        return try dbQueue.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO tasks (id, meeting_id, owner, text, status, dedupe_key, created_at)
                VALUES (?, ?, ?, ?, 'open', ?, strftime('%s','now'))
                """, arguments: [id, meetingID, owner, text, String(key)])
            return db.changesCount > 0 ? id : nil
        }
    }

    /// Replace the OPEN action items a summary pass produced for a call (keyed `sum:`), preserving any the
    /// user already completed. Lets "Regenerate" refresh the to-dos idempotently instead of piling up
    /// reworded duplicates every time (audit HIGH).
    public func setSummaryTasks(meetingID: String, items: [ActionItemDraft]) throws {
        try dbQueue.write { db in try Self.applySummaryTasks(db, meetingID: meetingID, items: items) }
    }

    /// Set the call summary AND its open summary-tasks ATOMICALLY (one transaction). Prevents the
    /// split-write where the summary committed but the tasks write failed — leaving a call that
    /// LOOKS summarized (so auto-backfill never retries) with its action items silently lost (B1).
    public func setSummaryAndTasks(meetingID: String, summary: String?, source: String?,
                                   items: [ActionItemDraft]) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE meetings SET call_summary = ?, summary_source = ?, updated_at = strftime('%Y-%m-%d %H:%M:%S','now') WHERE id = ?",
                           arguments: [summary, source, meetingID])
            try Self.applySummaryTasks(db, meetingID: meetingID, items: items)
        }
    }

    /// Replace a call's OPEN summary-tasks (`sum:` dedupe prefix) with `items`, owner-scoped
    /// cross-source de-dup. Runs inside a caller-provided transaction.
    static func applySummaryTasks(_ db: Database, meetingID: String, items: [ActionItemDraft]) throws {
            try db.execute(sql: "DELETE FROM tasks WHERE meeting_id = ? AND status = 'open' AND dedupe_key LIKE 'sum:%'",
                           arguments: [meetingID])
            // Cross-source dedupe (founder de-slop): a commitment the deterministic notes
            // extractor already captured must not appear twice on the same call. OWNER-SCOPED
            // (gate HIGH, same rule as every other dedupe): Alice's task never suppresses Bob's.
            let existingPairs: [(owner: String, text: String)] = try Row.fetchAll(db, sql:
                "SELECT owner, text FROM tasks WHERE meeting_id = ? AND dedupe_key NOT LIKE 'sum:%'",
                arguments: [meetingID]).map { (($0["owner"] as String?) ?? "", $0["text"]) }
            for it in items {
                let text = it.text.trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }
                let ownerKey = it.owner?.lowercased() ?? ""
                let sameOwner = existingPairs.filter { $0.owner.lowercased() == ownerKey }.map(\.text)
                guard !TaskIntelligence.isNearDuplicate(text, of: sameOwner, strict: true) else { continue }
                let key = "sum:\(it.owner?.lowercased() ?? "")|\(text.lowercased())"
                try db.execute(sql: """
                    INSERT OR IGNORE INTO tasks (id, meeting_id, owner, text, status, dedupe_key, created_at)
                    VALUES (?, ?, ?, ?, 'open', ?, strftime('%s','now'))
                    """, arguments: ["task_" + UUID().uuidString, meetingID, it.owner, text, String(key)])
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
            let rows = try Row.fetchAll(db, sql: "SELECT id, title, ai_title, date, source FROM meetings ORDER BY date_epoch DESC LIMIT ?",
                                        arguments: [limit])
            return try rows.map { r in
                let id: String = r["id"]
                let people = try String.fetchSet(db, sql:
                    "SELECT name_lower FROM meeting_entities WHERE meeting_id = ? AND kind = 'person'",
                    arguments: [id])
                return MeetingMeta(id: id, title: r["title"], smartTitle: r["ai_title"],
                                   date: r["date"], source: r["source"], people: people)
            }
        }
    }

    /// Fully delete a meeting and everything that could still hold its content (Codex P6 gate HIGH: the
    /// "transcript removed" promise must be true). Cascades chunks/embeddings/utterances/entities/tasks;
    /// deletes the meeting's own AskFred conversations (→ their messages); and SCRUBS stored citation
    /// excerpts referencing this meeting from any remaining (global) chat message.
    public func deleteMeeting(id: String) throws {
        vectorRevision.add(1)   // invalidate the whole-space vector cache (Task 5.2)
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
            // 2b) `import_jobs.meeting_id` is denormalized (no FK, so it survives meeting deletion by
            //     design) — but a dangling non-null id lets the Import UI navigate to missing content.
            //     Null it in the SAME txn (audit E MED), preserving the job's title/status/audit trail.
            try db.execute(sql: "UPDATE import_jobs SET meeting_id = NULL WHERE meeting_id = ?", arguments: [id])
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
        public let tStart: Double?       // chunk start time (s) — evidence timestamps (Task 1.2)
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
                       c.text AS text, c.start_timestamp AS t_start, bm25(chunks_fts) AS score
                FROM chunks_fts f
                JOIN transcript_chunks c ON c.chunk_id = f.chunk_id
                WHERE chunks_fts MATCH ?
                """
            var args: [(any DatabaseValueConvertible)?] = [terms]
            if let ids = candidateChunkIDs {
                // Pass the candidate set as ONE json array param (json_each) instead of N bound params — a
                // large date-range would otherwise exceed SQLite's bound-parameter limit and fail (audit MED).
                sql += " AND f.chunk_id IN (SELECT value FROM json_each(?))"
                args.append(Self.jsonArray(ids))
            }
            sql += " ORDER BY score LIMIT ?"
            args.append(limit)
            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            return rows.map { r in
                ChunkHit(chunkID: r["chunk_id"], meetingID: r["meeting_id"],
                         speaker: r["speaker"], text: r["text"], bm25: r["score"] ?? 0,
                         tStart: r["t_start"])
            }
        }
    }

    /// Encode a string list as a JSON array for `json_each(?)` IN-clauses — one bound param regardless of
    /// list size, so a large candidate set never hits SQLite's bound-parameter limit.
    static func jsonArray(_ items: [String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: items) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - vector lane (embeddings as BLOBs; V1 brute-force cosine, §0 D5/D6)

    public func saveEmbedding(chunkID: String, space: String, dim: Int, modelID: String,
                              vector: [Float], contentHash: String) throws {
        vectorRevision.add(1)   // invalidate the whole-space vector cache (Task 5.2)
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO embeddings (chunk_id, space, dim, model_id, vector, content_hash)
                VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [chunkID, space, dim, modelID, VectorMath.encode(vector), contentHash])
        }
    }

    /// All stored vectors for an embedding space, optionally restricted to a candidate `chunkIDs` set
    /// (the D6 selectivity-routed path: pre-filter in SQL, then exact brute-force over the subset).
    /// Monotonic revision bumped on every vector-affecting write — the cache's staleness key.
    let vectorRevision = CounterBox()
    private let vectorCache = VectorCacheBox()

    /// Whole-space vectors with a decode-once cache (Task 5.2 — the audit HIGH: every Ask
    /// decoded EVERY embedding BLOB from SQLite; on the growing archive that's pure waste).
    /// Scoped candidate queries bypass the cache (they're small and rare).
    /// ⚠ Invalidation is PER Store INSTANCE (gate LOW): an external live writer would leave
    /// this cache stale. Acceptable by design — every cbeval --apply mode enforces
    /// requireAppClosed() before opening the store, so no external writer coexists with the app.
    public func cachedVectors(space: String) throws -> [(id: String, vector: [Float])] {
        let rev = vectorRevision.value
        if let hit = vectorCache.get(space: space, revision: rev) { return hit }
        let rows = try vectors(space: space, chunkIDs: nil)
        vectorCache.set(space: space, revision: rev, rows: rows)
        return rows
    }

    public func vectors(space: String, chunkIDs: [String]? = nil) throws -> [(id: String, vector: [Float])] {
        // Semantics (Codex audit fix): nil = whole space; [] = NO candidates (an empty hard-filter
        // result must not fall through to "all vectors" and leak out-of-scope evidence).
        if let ids = chunkIDs, ids.isEmpty { return [] }
        return try dbQueue.read { db in
            let rows: [Row]
            if let ids = chunkIDs {        // non-empty (guarded above)
                // json_each so a large candidate set can't exceed SQLite's bound-parameter limit (audit MED).
                rows = try Row.fetchAll(db, sql:
                    "SELECT chunk_id, dim, vector FROM embeddings WHERE space = ? AND chunk_id IN (SELECT value FROM json_each(?))",
                    arguments: [space, Self.jsonArray(ids)])
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
        public var callSummary: String? = nil      // full markdown summary (Summary tab)
        public var summarySource: String? = nil    // "local" | "cloud" | "gemini"
        public var category: String? = nil         // "ambient" | "further_health" | "other"
        public var categoryManual: Bool = false    // user set it by hand → don't auto-overwrite
        /// The proper AI title if we have one, else the original (filename-derived) title.
        public var displayTitle: String { (aiTitle?.isEmpty == false) ? aiTitle! : title }
        static func from(_ r: Row) -> MeetingRow {
            MeetingRow(id: r["id"], title: r["title"], date: r["date"], source: r["source"],
                       aiTitle: r["ai_title"], aiSummary: r["ai_summary"],
                       callSummary: r["call_summary"], summarySource: r["summary_source"],
                       category: r["category"], categoryManual: (r["category_manual"] as Int? ?? 0) != 0)
        }
    }

    static let meetingCols = "id, title, date, source, ai_title, ai_summary, call_summary, summary_source, category, category_manual"

    /// E4 (Task 8.1): no arbitrary 200-row ceiling — the founder's archive will pass 200 within
    /// months of Drive auto-sync, and rows are lightweight metadata (no transcripts). 5000 is a
    /// generous guard against pathological stores, not a product limit.
    public func recentMeetings(limit: Int = 5000) throws -> [MeetingRow] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT \(Self.meetingCols) FROM meetings
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

    /// User rename of a call's display title. Writes `ai_title` (which `displayTitle` prefers), so the raw
    /// original title is preserved AND the auto-title pass won't overwrite it (it skips rows that already
    /// have an ai_title). Empty → clears the override, falling back to the original/auto title.
    public func setMeetingTitle(id: String, title: String) throws {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE meetings SET ai_title = ?, updated_at = strftime('%Y-%m-%d %H:%M:%S','now') WHERE id = ?",
                           arguments: [t.isEmpty ? nil : t, id])
        }
    }

    /// Persist the full call summary + where it came from (Summary tab).
    public func setCallSummary(id: String, summary: String?, source: String?) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE meetings SET call_summary = ?, summary_source = ?, updated_at = strftime('%Y-%m-%d %H:%M:%S','now') WHERE id = ?",
                           arguments: [summary, source, id])
        }
    }

    /// Persist a call's category. `manual` marks a user choice that auto-classification must not override.
    public func setCategory(id: String, category: String, confidence: Double?, manual: Bool) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                UPDATE meetings SET category = ?, category_confidence = ?, category_manual = ?,
                       updated_at = strftime('%Y-%m-%d %H:%M:%S','now') WHERE id = ?
                """, arguments: [category, confidence, manual ? 1 : 0, id])
        }
    }

    /// IDs of every call with no category yet (for launch backfill — not limited to the recent window, so
    /// older calls eventually get classified too).
    public func meetingsNeedingCategory(limit: Int = 5000) throws -> [String] {
        try dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM meetings WHERE category IS NULL OR category = '' LIMIT ?",
                                arguments: [limit])
        }
    }

    /// F4: reset every AUTO-classified category (manual picks kept) so a venture edit re-tags the WHOLE
    /// library against the new keyword set. The old backfill only touched never-classified calls, so adding
    /// a venture never rescued calls already sitting in auto-"other". Returns the number of rows cleared.
    @discardableResult
    public func clearAutoCategories() throws -> Int {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE meetings SET category = NULL WHERE category_manual = 0")
            return db.changesCount
        }
    }

    /// Auto-classification write — never overwrites a user's manual choice (the `category_manual = 0` guard
    /// closes the check-then-write race when a manual override lands during an in-flight classification).
    public func setAutoCategory(id: String, category: String, confidence: Double?) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                UPDATE meetings SET category = ?, category_confidence = ?,
                       updated_at = strftime('%Y-%m-%d %H:%M:%S','now')
                WHERE id = ? AND category_manual = 0
                """, arguments: [category, confidence, id])
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
            try Row.fetchOne(db, sql: "SELECT \(Self.meetingCols) FROM meetings WHERE id = ?", arguments: [id])
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
    /// Targeted task removal (Task 2.4 cross-half dedupe) — batched via json_each.
    public func deleteTasks(ids: [String]) throws {
        guard !ids.isEmpty else { return }
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM tasks WHERE id IN (SELECT value FROM json_each(?))",
                           arguments: [Self.jsonArray(ids)])
        }
    }

    /// Tasks with their dedupe keys — the audit/restore path (Codex phase-2 MED) needs the key
    /// to re-insert a wrongly-dropped task without inventing a new one.
    public func tasksWithKeys(meetingID: String) throws -> [(item: ActionItem, dedupeKey: String)] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql:
                "SELECT * FROM tasks WHERE meeting_id = ? ORDER BY created_at", arguments: [meetingID])
            return rows.map { r in
                (ActionItem(id: r["id"], meetingID: r["meeting_id"], owner: r["owner"], text: r["text"],
                            status: ActionItem.Status(rawValue: r["status"]) ?? .open,
                            sourceChunkID: r["source_chunk_id"], tStart: r["start_timestamp"],
                            createdAt: r["created_at"] ?? 0),
                 r["dedupe_key"] ?? "")
            }
        }
    }

    /// Re-insert a task dropped by an over-eager dedupe (audit restore). INSERT OR IGNORE: if an
    /// equivalent task already exists under the (meeting, dedupe_key) UNIQUE, nothing duplicates.
    public func restoreTask(_ item: ActionItem, dedupeKey: String, meetingID: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO tasks
                (id, meeting_id, owner, text, status, source_chunk_id, start_timestamp, dedupe_key, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [item.id, meetingID, item.owner, item.text, item.status.rawValue,
                                 item.sourceChunkID, item.tStart, dedupeKey, item.createdAt])
        }
    }

    // MARK: - pending embeddings (Task 5.1 — the Ollama-down IOU queue)

    public func enqueuePendingEmbeddings(chunkIDs: [String], space: String) throws {
        guard !chunkIDs.isEmpty else { return }
        try dbQueue.write { db in
            for id in chunkIDs {
                try db.execute(sql: "INSERT OR IGNORE INTO pending_embeddings (chunk_id, space) VALUES (?, ?)",
                               arguments: [id, space])
            }
        }
    }

    public func pendingEmbeddings(limit: Int = 200) throws -> [(chunkID: String, space: String)] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT chunk_id, space FROM pending_embeddings ORDER BY created_at LIMIT ?",
                             arguments: [limit])
                .map { ($0["chunk_id"], $0["space"]) }
        }
    }

    public func clearPendingEmbeddings(chunkIDs: [String]) throws {
        guard !chunkIDs.isEmpty else { return }
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM pending_embeddings WHERE chunk_id IN (SELECT value FROM json_each(?))",
                           arguments: [Self.jsonArray(chunkIDs)])
        }
    }

    /// Remove the newest assistant turn of a conversation (regenerate, Task 4.4 — round-2 MED:
    /// the in-memory tail surgery must match the persisted thread, or reload resurrects the old
    /// answer next to the new one).
    public func deleteLastAssistantMessage(conversationID: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                DELETE FROM messages WHERE id = (
                  SELECT id FROM messages WHERE conversation_id = ? AND role = 'assistant'
                  ORDER BY created_at DESC LIMIT 1)
                """, arguments: [conversationID])
        }
    }

    /// The most-mentioned person across the archive (empty-state suggestion seed, Task 4.4).
    public func topPersonEntity() throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(db, sql: """
                SELECT name FROM meeting_entities WHERE kind = 'person'
                GROUP BY name_lower ORDER BY SUM(count) DESC LIMIT 1
                """)
        }
    }

    /// The chunks immediately before/after one chunk in its meeting (Task 6.4 — questions
    /// arrive with their answers: a hit mid-exchange pulls its surrounding turns as context).
    public func neighborChunks(of chunkID: String) throws -> (prev: ChunkHit?, next: ChunkHit?) {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql:
                "SELECT meeting_id, seq FROM transcript_chunks WHERE chunk_id = ?", arguments: [chunkID])
            else { return (nil, nil) }
            let mid: String = row["meeting_id"]; let seq: Int = row["seq"]
            func fetch(_ s: Int) throws -> ChunkHit? {
                try Row.fetchOne(db, sql: """
                    SELECT chunk_id, meeting_id, speaker, text, start_timestamp
                    FROM transcript_chunks WHERE meeting_id = ? AND seq = ? LIMIT 1
                    """, arguments: [mid, s]).map {
                    ChunkHit(chunkID: $0["chunk_id"], meetingID: $0["meeting_id"],
                             speaker: $0["speaker"], text: $0["text"], bm25: 0,
                             tStart: $0["start_timestamp"])
                }
            }
            return (try fetch(seq - 1), try fetch(seq + 1))
        }
    }

    /// Escape SQL LIKE wildcards so a literal `%` / `_` (or `\`) in a speaker name is matched
    /// literally rather than acting as a wildcard. Used with `ESCAPE '\'`.
    static func escapeLike(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    /// Chunk IDs whose speaker matches a person name, newest meetings first (Task 6.2 — the
    /// person-boost retrieval lane for "what did Riley say").
    public func chunkIDs(speakerContains name: String, limit: Int = 200) throws -> [String] {
        try dbQueue.read { db in
            try String.fetchAll(db, sql: """
                SELECT c.chunk_id FROM transcript_chunks c
                JOIN meetings m ON m.id = c.meeting_id
                WHERE c.speaker LIKE ? ESCAPE '\\' COLLATE NOCASE
                ORDER BY m.date DESC, c.seq LIMIT ?
                """, arguments: ["%\(Self.escapeLike(name))%", limit])
        }
    }

    /// Chunk IDs for a speaker, optionally intersected with an existing date/meeting/latest-call scope.
    /// This is the HARD candidate set for person questions ("everything Alex said").
    public func chunkIDs(speakerMatching name: String, within candidateChunkIDs: [String]? = nil,
                         limit: Int = 500) throws -> [String] {
        if let ids = candidateChunkIDs, ids.isEmpty { return [] }
        return try dbQueue.read { db in
            var sql = """
                SELECT c.chunk_id FROM transcript_chunks c
                JOIN meetings m ON m.id = c.meeting_id
                WHERE c.speaker LIKE ? ESCAPE '\\' COLLATE NOCASE
                """
            var args: [(any DatabaseValueConvertible)?] = ["%\(Self.escapeLike(name))%"]
            if let ids = candidateChunkIDs {
                sql += " AND c.chunk_id IN (SELECT value FROM json_each(?))"
                args.append(Self.jsonArray(ids))
            }
            sql += " ORDER BY m.date DESC, c.seq LIMIT ?"
            args.append(limit)
            return try String.fetchAll(db, sql: sql, arguments: StatementArguments(args))
        }
    }

    /// The newest meeting by date ("catch me up on the latest call", Task 6.3).
    public func latestMeeting() throws -> MeetingRow? {
        try dbQueue.read { db in
            // Full column set — an id/title-only row made displayTitle fall back to the RAW
            // filename in dynamic suggestions (7.3 raw-title leak).
            try Row.fetchOne(db, sql:
                "SELECT \(Self.meetingCols) FROM meetings ORDER BY date DESC, created_at DESC LIMIT 1")
                .map(MeetingRow.from)
        }
    }

    /// Call durations in seconds (max utterance end), one batched query (Task 7.3 list rows).
    public func meetingDurations(ids: [String]) throws -> [String: Double] {
        guard !ids.isEmpty else { return [:] }
        return try dbQueue.read { db in
            var out: [String: Double] = [:]
            let rows = try Row.fetchAll(db, sql: """
                SELECT meeting_id, MAX(end_timestamp) AS dur FROM utterances
                WHERE meeting_id IN (SELECT value FROM json_each(?)) GROUP BY meeting_id
                """, arguments: [Self.jsonArray(ids)])
            for r in rows { out[r["meeting_id"]] = r["dur"] }
            return out
        }
    }

    /// Top person names per meeting (initials chips, Task 7.3) — one batched query.
    public func meetingPeople(ids: [String], perMeeting: Int = 3) throws -> [String: [String]] {
        guard !ids.isEmpty else { return [:] }
        return try dbQueue.read { db in
            var out: [String: [String]] = [:]
            let rows = try Row.fetchAll(db, sql: """
                SELECT meeting_id, name FROM meeting_entities
                WHERE kind = 'person' AND meeting_id IN (SELECT value FROM json_each(?))
                ORDER BY meeting_id, count DESC
                """, arguments: [Self.jsonArray(ids)])
            for r in rows {
                let mid: String = r["meeting_id"]
                if out[mid, default: []].count < perMeeting { out[mid, default: []].append(r["name"]) }
            }
            return out
        }
    }

    /// Lowercased person-entity names for one meeting (CrossSourceLinker overlap sanity check).
    public func personEntityNames(meetingID: String) throws -> Set<String> {
        try dbQueue.read { db in
            Set(try String.fetchAll(db, sql:
                "SELECT name_lower FROM meeting_entities WHERE meeting_id = ? AND kind = 'person'",
                arguments: [meetingID]))
        }
    }

    /// Conservation assert for merges (Task 2.3): tasks whose meeting no longer exists — must
    /// always be 0 (the FKs would normally guarantee it; this catches any future FK-off path).
    public func orphanTaskCount() throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql:
                "SELECT COUNT(*) FROM tasks WHERE meeting_id NOT IN (SELECT id FROM meetings)") ?? 0
        }
    }

    /// Batched header lookup for evidence assembly — one read for N meetings (avoids N+1).
    public func meetings(ids: [String]) throws -> [String: MeetingRow] {
        guard !ids.isEmpty else { return [:] }
        return try dbQueue.read { db in
            // Hydrate the FULL columns → `MeetingRow.from` populates ai_title, so cited-answer
            // source headers show the polished `displayTitle`, not the raw filename (audit E/A).
            let rows = try Row.fetchAll(db, sql:
                "SELECT \(Self.meetingCols) FROM meetings WHERE id IN (SELECT value FROM json_each(?))",
                arguments: [Self.jsonArray(ids)])
            var out: [String: MeetingRow] = [:]
            for r in rows { out[r["id"]] = MeetingRow.from(r) }
            return out
        }
    }

    /// Every on-device-transcribed meeting (`gmeet_local`) — the DateBackfill working set.
    public func transcribedMeetings() throws -> [MeetingRow] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql:
                "SELECT id, title, date, source FROM meetings WHERE source = ? ORDER BY date",
                arguments: [MeetingSource.gmeetLocal.rawValue])
            return rows.map { MeetingRow(id: $0["id"], title: $0["title"], date: $0["date"], source: $0["source"]) }
        }
    }

    /// Targeted date repair (DateBackfill only) — date is not in FTS, so no index work needed.
    public func updateMeetingDate(id: String, date: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE meetings SET date = ? WHERE id = ?", arguments: [date, id])
        }
    }

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
                "SELECT chunk_id, meeting_id, speaker, text, start_timestamp FROM transcript_chunks WHERE chunk_id IN (\(placeholders))",
                arguments: StatementArguments(ids))
            return rows.map { r in
                ChunkHit(chunkID: r["chunk_id"], meetingID: r["meeting_id"],
                         speaker: r["speaker"], text: r["text"], bm25: 0,
                         tStart: r["start_timestamp"])
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

    /// WAV payloads of import jobs that are NOT done and back a local file — the audio to PROTECT from a
    /// "clear all recordings" wipe so Retry keeps working. Queries the durable table (not the newest-100
    /// in-memory list), so a failed import beyond that window is still protected (audit F10).
    public func protectedImportPayloads() throws -> Set<String> {
        try dbQueue.read { db in
            Set(try String.fetchAll(db, sql: """
                SELECT payload FROM import_jobs
                WHERE state != 'done' AND payload_kind = 'file' AND payload IS NOT NULL
                """))
        }
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
        let stepsJSON = msg.steps.isEmpty ? nil
            : (try? JSONEncoder().encode(msg.steps)).flatMap { String(data: $0, encoding: .utf8) }
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO messages (id, conversation_id, role, text, citations_json, created_at, steps_json, provider)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [msg.id, msg.conversationID, msg.role.rawValue, msg.text, json,
                                 msg.createdAt, stepsJSON, msg.provider])
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
        let steps: [AskEngine.ReasoningStep] = (r["steps_json"] as String?)
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode([AskEngine.ReasoningStep].self, from: $0) } ?? []
        return Message(id: r["id"], conversationID: r["conversation_id"],
                       role: Message.Role(rawValue: r["role"]) ?? .user, text: r["text"],
                       citations: cites, createdAt: r["created_at"] ?? 0,
                       steps: steps, provider: r["provider"])
    }

    // MARK: - backup / restore (Phase 8)

    /// Write a clean, consistent snapshot of the whole database to `url` (a `.cbk` file) via SQLite
    /// `VACUUM INTO` — safe to run on the live DB (it's a transactional copy, no WAL fragments).
    public func backup(to url: URL) throws {
        // VACUUM INTO a UNIQUE temp, then atomically swap it into place — so a failed vacuum can't
        // destroy the previous good backup (the old code removed the destination first) (audit E MED).
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        let tmpPath = tmp.path.replacingOccurrences(of: "'", with: "''")
        try? FileManager.default.removeItem(at: tmp)
        do {
            try dbQueue.writeWithoutTransaction { db in try db.execute(sql: "VACUUM INTO '\(tmpPath)'") }
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }

    /// Copy a store to `destPath` through a READ-ONLY connection (Codex phase-0 HIGH: tools must
    /// never open the live app store read-write — `Store.init` runs migrations + WAL PRAGMAs).
    /// `VACUUM INTO` only writes the destination file, and SQLite permits it on read-only handles;
    /// no transaction wrapper (VACUUM can't run inside one).
    public static func readOnlySnapshot(of sourcePath: String, to destPath: String) throws {
        var config = Configuration()
        config.readonly = true
        let q = try DatabaseQueue(path: sourcePath, configuration: config)
        try? FileManager.default.removeItem(atPath: destPath)
        let escaped = destPath.replacingOccurrences(of: "'", with: "''")
        try q.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM INTO '\(escaped)'")
        }
    }

    /// Validate a `.cbk` is a real Recap backup before a restore overwrites the user's data. Opens
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

    /// Turn a user phrase into a safe FTS5 MATCH expression. Perfection-plan Task 1.1: the old
    /// version quoted every token and space-joined them — FTS5 reads that as implicit AND, so a
    /// natural question ("what did travis say about billing") matched ~nothing and the keyword
    /// half of hybrid retrieval was dead. Now: strip stopwords, OR-join content tokens (BM25
    /// still rewards multi-term matches), and preserve user-quoted phrases verbatim as phrase
    /// queries. If stripping removes everything, fall back to all tokens — never an empty MATCH.
    static func sanitizeFTS(_ s: String) -> String {
        var phrases: [String] = []
        var rest = s
        while let r = rest.range(of: #""([^"]+)""#, options: .regularExpression) {
            phrases.append(String(rest[r]).trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
            rest.removeSubrange(r)
        }
        let all = rest.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init)
        var toks = all.filter { $0.count > 1 && !Stopwords.fts.contains($0) }
        if toks.isEmpty && phrases.isEmpty { toks = all }
        let parts = phrases.map { "\"\($0.lowercased())\"" } + toks.map { "\"\($0)\"" }
        return parts.joined(separator: " OR ")
    }
}

/// Lock-guarded whole-space vector cache (Task 5.2). One entry per space; any revision bump
/// (write) invalidates. Sized for the single nomic space this app uses.
final class VectorCacheBox: @unchecked Sendable {
    private let lock = NSLock()
    private var store: [String: (revision: Int, rows: [(id: String, vector: [Float])])] = [:]
    func get(space: String, revision: Int) -> [(id: String, vector: [Float])]? {
        lock.lock(); defer { lock.unlock() }
        guard let e = store[space], e.revision == revision else { return nil }
        return e.rows
    }
    func set(space: String, revision: Int, rows: [(id: String, vector: [Float])]) {
        lock.lock(); defer { lock.unlock() }
        store[space] = (revision, rows)
    }
}
