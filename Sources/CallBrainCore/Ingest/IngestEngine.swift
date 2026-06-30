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

    /// Persist a parsed transcript end-to-end and return what landed.
    public func ingest(_ parsed: ParsedTranscript) async throws -> Outcome {
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
            contentFingerprint: "sha256:" + Self.sha256(parsed.utterances.map(\.text).joined(separator: "\n")))

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
        // Atomic (Codex audit fix): meeting + chunks + embeddings persist in ONE transaction, so a
        // failure can't leave a searchable but partially-embedded meeting.
        try store.saveMeeting(meeting, chunks: inputs, embeddings: embInputs)

        return Outcome(meetingID: meetingID, chunkCount: inputs.count, embedded: embInputs.count)
    }

    static func sha256(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
