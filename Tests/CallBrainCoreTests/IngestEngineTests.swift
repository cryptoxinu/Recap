import Testing
import Foundation
@testable import CallBrainCore

actor CapturedEmbedInputs {
    private var texts: [String] = []

    func record(_ newTexts: [String]) {
        texts = newTexts
    }

    func snapshot() -> [String] {
        texts
    }
}

struct CapturingEmbedder: Embedder {
    let modelID = "capture"
    let dim = 1
    let captured: CapturedEmbedInputs

    func embed(_ texts: [String], kind: EmbedKind) async throws -> [[Float]] {
        await captured.record(texts)
        return texts.map { _ in [1] }
    }
}

@Suite("IngestEngine (parse → chunk → embed → store)")
struct IngestEngineTests {

    private func freshStore() throws -> Store {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("cb-ingest-\(UUID().uuidString).sqlite").path
        return try Store(path: path)
    }

    @Test("ingest a Fireflies export end-to-end → stored, embedded, searchable")
    func ingestFireflies() async throws {
        let store = try freshStore()
        let embedder = StubEmbedder()
        let space = "stub__v1"
        let engine = IngestEngine(store: store, embedder: embedder, space: space)

        let outcome = try await engine.ingestFireflies(Data(FirefliesParserTests.sample.utf8))
        #expect(outcome.chunkCount == 3)              // 3 utterances, speaker changes each → 3 chunks
        #expect(outcome.embedded == 3)
        #expect(try store.meetingCount() == 1)
        #expect(try store.embeddingCount(space: space) == 3)

        // searchable through the same engine that powers Ask
        let search = SearchEngine(store: store, embedder: embedder, space: space)
        let hits = try await search.hybrid("inference hardware")
        #expect(hits.contains { $0.text.contains("inference hardware") })
    }

    @Test("ingest a Fathom copy end-to-end")
    func ingestFathom() async throws {
        let store = try freshStore()
        let engine = IngestEngine(store: store, embedder: StubEmbedder(), space: "stub__v1")
        let outcome = try await engine.ingestFathom(FathomParserTests.sample)
        #expect(outcome.chunkCount == 3)
        #expect(outcome.embedded == 3)
        #expect(try store.chunkCount() == 3)
    }

    @Test("content hash is stable for identical text (idempotency foundation)")
    func stableHash() {
        #expect(IngestEngine.sha256("Render") == IngestEngine.sha256("Render"))
        #expect(IngestEngine.sha256("a") != IngestEngine.sha256("b"))
        #expect(IngestEngine.sha256("Render").count == 64)   // hex SHA-256
    }

    // P2c "never lose a silent recording": the no-speech placeholder always ingests the SAME text
    // ("No speech was detected in this recording."), so it MUST dedupe on the file PATH, not the body —
    // else two different silent recordings collapse into one and the founder still "can't find the call".
    @Test("identical placeholder text with different fingerprints yields distinct findable meetings")
    func distinctFingerprintsNeverCollapse() async throws {
        let store = try freshStore()
        let engine = IngestEngine(store: store, embedder: StubEmbedder(), space: "stub__v1")
        func silent(_ title: String) -> ParsedTranscript {
            ParsedTranscript(title: title, date: "2027-02-01", source: .gmeetLocal, speakers: ["CallBrain"],
                             utterances: [ParsedUtterance(seq: 0, speakerRaw: "CallBrain", tStart: 0, tEnd: 0,
                                          text: "No speech was detected in this recording.")])
        }
        let a = try await engine.ingest(silent("Recording · Feb 1, 9:00 AM"), dedupeFingerprint: "nospeech:/tmp/a.wav")
        let b = try await engine.ingest(silent("Recording · Feb 1, 2:00 PM"), dedupeFingerprint: "nospeech:/tmp/b.wav")
        #expect(a.deduped == false)
        #expect(b.deduped == false)
        #expect(a.meetingID != b.meetingID)                 // two findable rows, not one
        #expect(try store.meetingCount() == 2)
        // Re-import of the SAME file (same fingerprint) still dedupes — no runaway duplicates on retry.
        let again = try await engine.ingest(silent("Recording · Feb 1, 9:00 AM"), dedupeFingerprint: "nospeech:/tmp/a.wav")
        #expect(again.deduped == true)
        #expect(again.meetingID == a.meetingID)
        #expect(try store.meetingCount() == 2)
    }

    @Test("re-ingesting identical content is idempotent (deduped, no duplicate, no re-embed)")
    func dedupes() async throws {
        let store = try freshStore()
        let space = "stub__v1"
        let engine = IngestEngine(store: store, embedder: StubEmbedder(), space: space)

        let first = try await engine.ingestFathom(FathomParserTests.sample)
        #expect(first.deduped == false)
        #expect(first.embedded == 3)

        let again = try await engine.ingestFathom(FathomParserTests.sample)
        #expect(again.deduped == true)
        #expect(again.meetingID == first.meetingID)        // same meeting returned
        #expect(again.chunkCount == 3)
        #expect(again.embedded == 0)                       // skipped the embedding cost
        #expect(try store.meetingCount() == 1)             // no duplicate row
        #expect(try store.embeddingCount(space: space) == 3)
    }

    @Test("dedupe keys on date + speakers: same body different day is NOT deduped (audit M1)")
    func dedupeRespectsDateAndSpeaker() async throws {
        let store = try freshStore()
        let engine = IngestEngine(store: store, embedder: StubEmbedder(), space: "stub__v1")

        func notes(date: String) -> ParsedTranscript {
            ParsedTranscript(title: "Daily standup", date: date, source: .gmeetGemini,
                speakers: ["Gemini Notes"],
                utterances: [ParsedUtterance(seq: 0, speakerRaw: "Gemini Notes", tStart: 0, tEnd: 0,
                                             text: "We discussed Render pricing and GPU costs.", tsConfidence: .none)])
        }
        _ = try await engine.ingest(notes(date: "2026-06-29"))
        let day2 = try await engine.ingest(notes(date: "2026-06-30"))   // identical body, next day
        #expect(day2.deduped == false)                     // different meeting, not collapsed
        #expect(try store.meetingCount() == 2)

        // speaker-swap with identical utterance texts must not collide
        func swap(_ a: String, _ b: String) -> ParsedTranscript {
            ParsedTranscript(title: "Sync", date: "2026-07-01", source: .fireflies, speakers: [a, b],
                utterances: [ParsedUtterance(seq: 0, speakerRaw: a, tStart: 0, tEnd: 1, text: "Yes."),
                             ParsedUtterance(seq: 1, speakerRaw: b, tStart: 1, tEnd: 2, text: "No.")])
        }
        _ = try await engine.ingest(swap("Alice", "Bob"))
        let swapped = try await engine.ingest(swap("Bob", "Alice"))
        #expect(swapped.deduped == false)                  // speaker order differs → distinct
    }

    @Test("document embeddings include compact metadata header and hash it")
    func enrichedEmbeddingInputAndHash() async throws {
        let store = try freshStore()
        let captured = CapturedEmbedInputs()
        let engine = IngestEngine(store: store, embedder: CapturingEmbedder(captured: captured),
                                  space: "capture__v1")
        let parsed = ParsedTranscript(
            title: "Infra Sync", date: "2026-07-04", source: .paste, speakers: ["Riley"],
            utterances: [ParsedUtterance(seq: 0, speakerRaw: "Riley", speakerConfidence: nil,
                                         tStart: 0, tEnd: 5, text: "Render GPU pricing",
                                         isInferredSpeaker: false, tsConfidence: .exact)])

        let outcome = try await engine.ingest(parsed)
        let embeddedText = try #require(await captured.snapshot().first)
        #expect(embeddedText == "[Infra Sync · 2026-07-04 · Riley]\nRender GPU pricing")

        let storedChunk = try #require(try store.chunks(ids: ["\(outcome.meetingID)_c0"]).first)
        #expect(storedChunk.text == "Render GPU pricing")

        let bareHash = "sha256:" + IngestEngine.sha256("Render GPU pricing")
        let travisHash = IngestEngine.embeddingContentHash(title: "Infra Sync", date: "2026-07-04",
                                                           speaker: "Riley", text: "Render GPU pricing")
        let maxHash = IngestEngine.embeddingContentHash(title: "Infra Sync", date: "2026-07-04",
                                                        speaker: "Dom", text: "Render GPU pricing")
        let retitledHash = IngestEngine.embeddingContentHash(title: "Infra Review", date: "2026-07-04",
                                                             speaker: "Riley", text: "Render GPU pricing")
        #expect(travisHash == "sha256:" + IngestEngine.sha256(embeddedText))
        #expect(travisHash != bareHash)
        #expect(travisHash != maxHash)
        #expect(travisHash != retitledHash)
    }
}
