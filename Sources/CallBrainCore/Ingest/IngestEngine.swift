import Foundation
import CryptoKit

public enum IngestError: Error, Sendable, Equatable {
    case embeddingCountMismatch(expected: Int, got: Int)
}

public enum ReadError: Error, Sendable, Equatable {
    case tooLarge(mb: Int)      // a file/transcript past the sane import ceiling (OOM / zip-bomb guard)
}

/// Ties the ingestion pipeline together (docs/ARCHITECTURE.md §6): a parsed transcript →
/// CTM utterances → speaker-turn chunks → embeddings → persisted + searchable. Phase 1 takes an
/// explicit source (Fireflies/Fathom); the auto-detecting router + durable state machine land in Phase 2.
public struct IngestEngine: Sendable {
    public let store: Store
    public let embedder: any Embedder
    public let space: String
    public let chunker: Chunker

    public init(store: Store, embedder: any Embedder, space: String, chunker: Chunker = Chunker()) {
        self.store = store; self.embedder = embedder; self.space = space; self.chunker = chunker
    }

    public struct Outcome: Sendable, Equatable {
        public let meetingID: String
        public let chunkCount: Int
        public let embedded: Int
        public var deduped: Bool = false   // true when an identical meeting already existed (no re-ingest)
    }

    public func ingestFireflies(_ data: Data) async throws -> Outcome {
        try await ingest(FirefliesParser.parse(data))
    }
    public func ingestFathom(_ text: String) async throws -> Outcome {
        try await ingest(FathomParser.parse(text))
    }
    public func ingestFirefliesCopy(_ text: String) async throws -> Outcome {
        try await ingest(FirefliesCopyParser.parse(text))
    }
    public func ingestGeminiNotes(_ text: String, title: String? = nil, date: String? = nil) async throws -> Outcome {
        try await ingest(GeminiNotesParser.parse(text, title: title, date: date))
    }

    /// "Paste anything" import: an `AIImporter` resolves a raw dump (known format → deterministic,
    /// else AI), names it, and this stores it. Returns the resolved format + whether AI was used.
    public func ingestRaw(_ raw: String, importer: AIImporter,
                          generateTitleIfMissing: Bool = true) async throws -> (Outcome, AIImporter.Resolved) {
        let resolved = try await importer.resolve(raw, generateTitleIfMissing: generateTitleIfMissing)
        let outcome = try await ingest(resolved.transcript)
        return (outcome, resolved)
    }

    /// Drag-and-drop / file-open import (Phase 2): read the file's text natively (`.docx` via
    /// `DocxReader`, everything else as UTF-8), seed title/date from the filename, then route through
    /// the same detect→parse→AI-resolve pipeline as paste. One entry point for every on-disk source.
    public func ingestFile(at url: URL, importer: AIImporter,
                           generateTitleIfMissing: Bool = true) async throws -> (Outcome, AIImporter.Resolved) {
        let text = try Self.readText(at: url)
        let meta = Self.filenameMeta(url)
        let resolved = try await importer.resolve(text, generateTitleIfMissing: generateTitleIfMissing,
                                                  titleHint: meta.title, dateHint: meta.date,
                                                  fileExtension: url.pathExtension)
        let outcome = try await ingest(resolved.transcript)
        return (outcome, resolved)
    }

    /// Extensions this engine can read off disk (used by the drop target to accept/reject files).
    public static let readableExtensions: Set<String> = ["docx", "txt", "md", "json", "srt", "vtt"]
    /// A transcript past this on-disk size is rejected before reading (OOM / accidental-huge-file guard).
    /// Real meeting transcripts are KBs–low-MBs; 64 MB is already ~weeks of dense talk.
    public static let maxReadBytes = 64 * 1024 * 1024

    static func readText(at url: URL) throws -> String {
        if url.pathExtension.lowercased() == "docx" { return try DocxReader.read(url: url) }
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > maxReadBytes {
            throw ReadError.tooLarge(mb: size / (1024 * 1024))
        }
        // Many real transcript/subtitle exports (SRT/VTT, Windows tools) are NOT UTF-8 — fall back to
        // the system's best guess, then Windows-1252, then Latin-1 (never fails), so a single curly
        // apostrophe (0x92) doesn't reject a perfectly valid transcript with a cryptic error (SME H1).
        if let s = try? String(contentsOf: url, encoding: .utf8) { return s }
        var used = String.Encoding.utf8
        if let s = try? String(contentsOf: url, usedEncoding: &used) { return s }
        let data = try Data(contentsOf: url)
        return String(data: data, encoding: .windowsCP1252)
            ?? String(data: data, encoding: .isoLatin1)
            ?? String(decoding: data, as: UTF8.self)
    }

    /// Best-effort title + date from a filename like
    /// `morning sync - 2026_06_29 09_29 PDT - Notes by Gemini (1).docx` → ("morning sync", "2026-06-29").
    /// Public since Task 2.1: ImportCoordinator dates transcribed recordings from the filename
    /// (they were stamped with the IMPORT day — every date-scoped answer about them was wrong).
    /// Strip a recording's filename disambiguation stamp (`" — yyyy-MM-dd HHmm"` + an optional ` (N)`
    /// counter) so a recorded call's title reads cleanly ("Partner sync"), not "Partner sync — 2026-07-11
    /// 1430". Only the EXACT stamp shape RecordingModel appends is removed, so ordinary imported filenames
    /// are untouched. Never returns empty (falls back to the original stem).
    public static func stripRecordingStamp(_ stem: String) -> String {
        let pattern = #"\s+—\s+\d{4}-\d{2}-\d{2}\s+\d{4}(\s+\(\d+\))?$"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return stem }
        let ns = stem as NSString
        let cleaned = re.stringByReplacingMatches(in: stem, range: NSRange(location: 0, length: ns.length),
                                                  withTemplate: "").trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? stem : cleaned
    }

    public static func filenameMeta(_ url: URL) -> (title: String?, date: String?) {
        let stem = url.deletingPathExtension().lastPathComponent
        let ns = stem as NSString

        var date: String?
        if let re = try? NSRegularExpression(pattern: #"(\d{4})[-_](\d{2})[-_](\d{2})"#),
           let m = re.firstMatch(in: stem, range: NSRange(location: 0, length: ns.length)) {
            let (y, mo, d) = (Int(ns.substring(with: m.range(at: 1))) ?? 0,
                              Int(ns.substring(with: m.range(at: 2))) ?? 0,
                              Int(ns.substring(with: m.range(at: 3))) ?? 0)
            // Plausibility gate — a Drive ID's digit runs must never become a "date".
            if (2000...2099).contains(y), (1...12).contains(mo), (1...31).contains(d) {
                date = String(format: "%04d-%02d-%02d", y, mo, d)
            }
        }

        var title = stem
        if let r = stem.range(of: #"\s*[-–]\s*\d{4}[-_]\d{2}[-_]\d{2}"#, options: .regularExpression) {
            title = String(stem[..<r.lowerBound])              // everything before " - 2026_06_29"
        } else if let dash = stem.range(of: " - ") {
            title = String(stem[..<dash.lowerBound])
        }
        title = title.trimmingCharacters(in: .whitespaces)
        return (title.isEmpty ? nil : title, date)
    }

    /// Persist a parsed transcript end-to-end and return what landed.
    /// Content fingerprint for dedupe = SHA-256 of date + per-utterance (speaker, text). Including the
    /// DATE stops a recurring standup with identical body on a different day from being wrongly deduped,
    /// and the per-utterance SPEAKER stops a speaker-swap from colliding (SME audit M1). The volatile
    /// AI-generated TITLE is deliberately excluded so a re-paste of the same text still dedupes.
    public static func fingerprint(for parsed: ParsedTranscript) -> String {
        let body = parsed.utterances.map { "\($0.speakerRaw)\u{1}\($0.text)" }.joined(separator: "\n")
        return "sha256:" + sha256((parsed.date ?? "") + "\u{2}" + body)
    }

    /// - Parameter dedupeFingerprint: precomputed fingerprint to dedupe on, when the CALLER wants to
    ///   store a transformed (e.g. vocabulary-corrected) transcript while still deduping on the RAW one —
    ///   so the same recording still dedupes across dictionary/seed changes (audit MED). nil = compute
    ///   from `parsed` (the normal path).
    public func ingest(_ parsed: ParsedTranscript, dedupeFingerprint: String? = nil) async throws -> Outcome {
        // Idempotency (tier-1): identical content already ingested → return it, skipping the embedding
        // cost and avoiding a duplicate meeting.
        let fingerprint = dedupeFingerprint ?? Self.fingerprint(for: parsed)
        if let existing = try store.existingMeeting(contentHash: fingerprint) {
            return Outcome(meetingID: existing.id, chunkCount: existing.chunks, embedded: 0, deduped: true)
        }

        // Apply the learned vocabulary (crypto/company glossary + the founder's approved corrections) to the
        // STORED transcript for EVERY source — Fathom / Google-Meet / paste / file / recording — so search
        // and AI answers see the right spelling, not just the on-screen display. Dedupe already keyed off the
        // RAW transcript above, so this never affects idempotency; the correction pass is itself idempotent
        // (safe even for the recording path, which used to pre-apply it).
        let parsed = CorrectionDictionary.load().apply(to: parsed)

        let meetingID = "m_" + UUID().uuidString

        let utterances = parsed.utterances.map { pu in
            Utterance(id: "\(meetingID)_u\(pu.seq)", meetingID: meetingID, version: 0, seq: pu.seq,
                      speakerRaw: pu.speakerRaw, speakerConfidence: pu.speakerConfidence,
                      tStart: pu.tStart, tEnd: pu.tEnd, text: pu.text,
                      isInferredSpeaker: pu.isInferredSpeaker, tsConfidence: pu.tsConfidence)
        }
        let chunks = chunker.chunk(utterances)

        // Embed all chunks in one batch (document side of the single embedding model). The compact
        // header gives person/title/date queries retrieval signal without changing stored chunk text.
        let embeddingTexts = chunks.map {
            Self.embeddingText(title: parsed.title, date: parsed.date, speaker: $0.speaker, text: $0.text)
        }
        // Ollama down MUST NOT fail the import (Task 5.1a — audit P0-7: text + FTS land now;
        // vectors are queued for the backfill job and arrive when the embedder returns).
        var vectors: [[Float]] = []
        var embedderDown = false
        if !chunks.isEmpty {
            do { vectors = try await embedder.embed(embeddingTexts, kind: .document) }
            catch { embedderDown = true; vectors = [] }
        }
        // Never persist a PARTIALLY-embedded meeting (Codex audit fix): all vectors or none.
        guard vectors.isEmpty || vectors.count == chunks.count else {
            throw IngestError.embeddingCountMismatch(expected: chunks.count, got: vectors.count)
        }

        let meeting = Meeting(
            id: meetingID,
            title: parsed.title ?? "Untitled meeting",
            date: parsed.date ?? TimeCode.ymd(Date()),
            startedAt: parsed.startedAt,
            durationSeconds: parsed.durationSeconds,
            source: parsed.source,
            contentFingerprint: fingerprint)

        let inputs = chunks.map { ch in
            Store.ChunkInput(chunkID: "\(meetingID)_c\(ch.seq)", meetingID: meetingID, version: 0,
                             seq: ch.seq, speaker: ch.speaker, tStart: ch.tStart, tEnd: ch.tEnd,
                             text: ch.text, tokenCount: ch.approxTokens,
                             contentHash: "sha256:" + Self.sha256(ch.text))
        }
        let embInputs: [Store.EmbeddingInput] = vectors.isEmpty ? [] : chunks.enumerated().map { i, ch in
            Store.EmbeddingInput(chunkID: "\(meetingID)_c\(ch.seq)", space: space, dim: embedder.dim,
                                 modelID: embedder.modelID, vector: vectors[i],
                                 contentHash: Self.embeddingContentHash(title: parsed.title, date: parsed.date,
                                                                         speaker: ch.speaker, text: ch.text))
        }
        // Persist the individual speaker turns too (the readable Transcript Viewer unit).
        let uttInputs = utterances.map { u in
            Store.UtteranceInput(id: u.id, meetingID: meetingID, version: u.version, seq: u.seq,
                                 speaker: u.speakerRaw, personID: u.personID,
                                 speakerConfidence: u.speakerConfidence, isInferredSpeaker: u.isInferredSpeaker,
                                 tStart: u.tStart, tEnd: u.tEnd, tsConfidence: u.tsConfidence.rawValue, text: u.text)
        }
        // Native on-device NER over the full text → searchable entity tags (people/orgs/places).
        let fullText = parsed.utterances.map(\.text).joined(separator: "\n")
        var entityInputs = EntityExtractor.extract(fullText).map {
            Store.EntityInput(name: $0.name, kind: $0.kind.rawValue, count: $0.count)
        }
        // Seed the NAMED participants as person entities too — NER over the body misses a speaker
        // who never appears IN the transcript text ("what did Riley say" then found nothing because
        // Riley was only ever a speaker label) (audit D13). Skip generic Speaker-N / Unknown labels
        // and anything NER already captured.
        let knownPersons = Set(entityInputs.filter { $0.kind == EntityKind.person.rawValue }.map { $0.name.lowercased() })
        var seededSpeakers = Set<String>()
        for s in parsed.speakers {
            let low = s.lowercased()
            // Seed only PLAUSIBLE person speakers (audit: raw seeded labels bypassed the noise filter, so
            // a non-person speaker like "Gemini Notes" leaked into People). isLikelyPersonName screens
            // tool/tech/product labels + stoplist words while keeping real names.
            guard !SpeakerResolver.isGeneric(s), s != SpeakerAligner.unattributed,
                  EntityExtractor.isLikelyPersonName(s),
                  !knownPersons.contains(low), seededSpeakers.insert(low).inserted else { continue }
            entityInputs.append(Store.EntityInput(name: s, kind: EntityKind.person.rawValue, count: 1))
        }
        // Action items: deterministic lift from Gemini notes (`[Owner]` lines + action/next-steps
        // sections) — the founder's real data yields tasks with no LLM cost. Transcript LLM-extraction
        // layers on later. dedupeKey = owner|text so re-ingest never duplicates or clobbers a toggled task.
        let taskInputs: [Store.TaskInput] = parsed.source == .gmeetGemini
            ? ActionItemExtractor.fromNotes(parsed.utterances).enumerated().map { i, e in
                Store.TaskInput(id: "\(meetingID)_t\(i)", owner: e.owner, text: e.text,
                                dedupeKey: "\(e.owner?.lowercased() ?? "")|\(e.text.lowercased())")
              }
            : []
        // Atomic (Codex audit fix): meeting + chunks + embeddings + utterances + entities + tasks persist
        // in ONE transaction, so a failure can't leave a searchable but partially-embedded meeting.
        // Ollama-down IOUs ride the SAME transaction (gate MED: a separate enqueue could fail
        // after the save, and content_hash dedupe would leave the meeting forever unembedded).
        do {
            try store.saveMeeting(meeting, chunks: inputs, embeddings: embInputs,
                                  utterances: uttInputs, entities: entityInputs, tasks: taskInputs,
                                  pendingEmbeddingSpace: embedderDown ? space : nil)
        } catch let StoreError.duplicateContent(existingID) {
            // A concurrent ingest committed the identical content between our read-check and this
            // write — return the twin as a dedupe hit instead of a second copy (audit D4/E).
            let n = (try? store.existingMeeting(contentHash: fingerprint))?.chunks ?? inputs.count
            return Outcome(meetingID: existingID, chunkCount: n, embedded: 0, deduped: true)
        }

        return Outcome(meetingID: meetingID, chunkCount: inputs.count, embedded: embInputs.count)
    }

    static func sha256(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Document-side embedding input. Only the embedding text/hash use this; persisted chunk text and
    /// chunk content hashes stay bare so FTS/citations/dedupe behavior does not move under callers.
    public static func embeddingText(title: String?, date: String?, speaker: String?, text: String) -> String {
        let fields = [title, date, speaker].compactMap(embeddingHeaderField)
        guard !fields.isEmpty else { return text }
        return "[\(fields.joined(separator: " · "))]\n\(text)"
    }

    public static func embeddingContentHash(title: String?, date: String?, speaker: String?, text: String) -> String {
        "sha256:" + sha256(embeddingText(title: title, date: date, speaker: speaker, text: text))
    }

    private static let maxEmbeddingHeaderFieldCharacters = 80

    private static func embeddingHeaderField(_ value: String?) -> String? {
        let normalized = value?
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ") ?? ""
        guard !normalized.isEmpty else { return nil }
        return String(normalized.prefix(maxEmbeddingHeaderFieldCharacters))
    }
}
