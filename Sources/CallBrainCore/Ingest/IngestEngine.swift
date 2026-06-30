import Foundation
import CryptoKit

public enum IngestError: Error, Sendable, Equatable {
    case embeddingCountMismatch(expected: Int, got: Int)
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
                                                  titleHint: meta.title, dateHint: meta.date)
        let outcome = try await ingest(resolved.transcript)
        return (outcome, resolved)
    }

    /// Extensions this engine can read off disk (used by the drop target to accept/reject files).
    public static let readableExtensions: Set<String> = ["docx", "txt", "md", "json", "srt", "vtt"]

    static func readText(at url: URL) throws -> String {
        if url.pathExtension.lowercased() == "docx" { return try DocxReader.read(url: url) }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Best-effort title + date from a filename like
    /// `morning sync - 2026_06_29 09_29 PDT - Notes by Gemini (1).docx` → ("morning sync", "2026-06-29").
    static func filenameMeta(_ url: URL) -> (title: String?, date: String?) {
        let stem = url.deletingPathExtension().lastPathComponent
        let ns = stem as NSString

        var date: String?
        if let re = try? NSRegularExpression(pattern: #"(\d{4})[-_](\d{2})[-_](\d{2})"#),
           let m = re.firstMatch(in: stem, range: NSRange(location: 0, length: ns.length)) {
            date = "\(ns.substring(with: m.range(at: 1)))-\(ns.substring(with: m.range(at: 2)))-\(ns.substring(with: m.range(at: 3)))"
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
    public func ingest(_ parsed: ParsedTranscript) async throws -> Outcome {
        // Idempotency (tier-1): identical content already ingested → return it, skipping the embedding
        // cost and avoiding a duplicate meeting. Fingerprint = SHA-256 of the ordered utterance texts.
        let fingerprint = "sha256:" + Self.sha256(parsed.utterances.map(\.text).joined(separator: "\n"))
        if let existing = try store.existingMeeting(contentHash: fingerprint) {
            return Outcome(meetingID: existing.id, chunkCount: existing.chunks, embedded: 0, deduped: true)
        }

        let meetingID = "m_" + UUID().uuidString

        let utterances = parsed.utterances.map { pu in
            Utterance(id: "\(meetingID)_u\(pu.seq)", meetingID: meetingID, version: 0, seq: pu.seq,
                      speakerRaw: pu.speakerRaw, speakerConfidence: pu.speakerConfidence,
                      tStart: pu.tStart, tEnd: pu.tEnd, text: pu.text,
                      isInferredSpeaker: pu.isInferredSpeaker, tsConfidence: pu.tsConfidence)
        }
        let chunks = chunker.chunk(utterances)

        // Embed all chunk texts in one batch (document side of the single embedding model).
        let vectors = chunks.isEmpty ? [] : try await embedder.embed(chunks.map(\.text), kind: .document)
        // Never persist a partially-embedded meeting (Codex audit fix): every chunk must get a vector.
        guard vectors.count == chunks.count else {
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
        let embInputs = chunks.enumerated().map { i, ch in
            Store.EmbeddingInput(chunkID: "\(meetingID)_c\(ch.seq)", space: space, dim: embedder.dim,
                                 modelID: embedder.modelID, vector: vectors[i],
                                 contentHash: "sha256:" + Self.sha256(ch.text))
        }
        // Persist the individual speaker turns too (the readable Transcript Viewer unit).
        let uttInputs = utterances.map { u in
            Store.UtteranceInput(id: u.id, meetingID: meetingID, version: u.version, seq: u.seq,
                                 speaker: u.speakerRaw, personID: u.personID,
                                 speakerConfidence: u.speakerConfidence, isInferredSpeaker: u.isInferredSpeaker,
                                 tStart: u.tStart, tEnd: u.tEnd, tsConfidence: u.tsConfidence.rawValue, text: u.text)
        }
        // Atomic (Codex audit fix): meeting + chunks + embeddings + utterances persist in ONE
        // transaction, so a failure can't leave a searchable but partially-embedded meeting.
        try store.saveMeeting(meeting, chunks: inputs, embeddings: embInputs, utterances: uttInputs)

        return Outcome(meetingID: meetingID, chunkCount: inputs.count, embedded: embInputs.count)
    }

    static func sha256(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
