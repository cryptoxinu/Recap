import Testing
import Foundation
@testable import CallBrainCore

/// Retroactive vocabulary correction of stored transcripts (#42 / TC5): fixes utterances + chunks and
/// re-syncs the FTS index so KEYWORD search over OLD calls finds the corrected term.
@Suite("Store.recorrectTranscripts")
struct StoreCorrectionsTests {
    private func seeded() throws -> Store {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("cb-recorrect-\(UUID().uuidString).sqlite").path
        let store = try Store(path: path)
        let m = Meeting(id: "m1", title: "crypto sync", date: "2026-07-05", source: .fireflies)
        let chunk = Store.ChunkInput(chunkID: "c1", meetingID: "m1", version: 0, seq: 0, speaker: "Them",
                                     tStart: 0, tEnd: 5, text: "we bridge to aetherium and solano next week",
                                     contentHash: "sha256:old")
        let utt = Store.UtteranceInput(id: "u1", meetingID: "m1", version: 0, seq: 0, speaker: "Them",
                                       tStart: 0, tEnd: 5, tsConfidence: "exact",
                                       text: "we bridge to aetherium and solano next week")
        try store.saveMeeting(m, chunks: [chunk], utterances: [utt])
        return store
    }

    private var applicator: CorrectionDictionary.Applicator {
        CorrectionDictionary(entries: [
            CorrectionEntry(wrong: "aetherium", right: "Ethereum"),
            CorrectionEntry(wrong: "solano", right: "Solana"),
        ]).makeApplicator()
    }

    @Test("rewrites stored chunk + utterance text and queues the changed chunk for re-embed")
    func testRewritesStoredText() throws {
        let store = try seeded()
        let result = try store.recorrectTranscripts(meetingIDs: nil, applicator: applicator, space: "nomic__v1")

        #expect(result.chunks == 1)
        #expect(result.utterances == 1)

        let chunk = try store.chunks(ids: ["c1"]).first
        #expect(chunk?.text == "we bridge to Ethereum and Solana next week")
        // The changed chunk was enqueued for re-embedding IN THE SAME transaction (audit HIGH).
        #expect(try store.pendingEmbeddings(limit: 10).contains { $0.chunkID == "c1" })
    }

    @Test("keyword search over the OLD call now finds the corrected term (FTS re-synced)")
    func testFTSReindexedAfterCorrection() throws {
        let store = try seeded()
        #expect(try store.keywordSearch("Ethereum", limit: 5).isEmpty)          // before: not found
        #expect(!(try store.keywordSearch("aetherium", limit: 5).isEmpty))       // before: the wrong form is there

        _ = try store.recorrectTranscripts(meetingIDs: nil, applicator: applicator, space: "nomic__v1")

        #expect(!(try store.keywordSearch("Ethereum", limit: 5).isEmpty))        // after: corrected term found
        #expect(try store.keywordSearch("aetherium", limit: 5).isEmpty)          // after: wrong form gone
    }

    @Test("meetingIDsContaining targets only calls with the term; re-run is an idempotent no-op")
    func testTargetingAndIdempotence() throws {
        let store = try seeded()
        #expect(try store.meetingIDsContaining("aetherium") == ["m1"])
        #expect(try store.meetingIDsContaining("dogecoin").isEmpty)

        _ = try store.recorrectTranscripts(meetingIDs: ["m1"], applicator: applicator, space: "nomic__v1")
        // Second run finds nothing to change (already corrected) — no spurious writes/re-embeds.
        let again = try store.recorrectTranscripts(meetingIDs: ["m1"], applicator: applicator, space: "nomic__v1")
        #expect(again.chunks == 0)
    }

    @Test("repeated sweeps are idempotent even with a chained dictionary (foo→bar, bar→baz) — audit MED")
    func testChainedDictionaryIsIdempotentAcrossSweeps() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("cb-recorrect-chain-\(UUID().uuidString).sqlite").path
        let store = try Store(path: path)
        try store.saveMeeting(Meeting(id: "m1", title: "t", date: "2026-07-05", source: .fireflies),
                              chunks: [Store.ChunkInput(chunkID: "c1", meetingID: "m1", version: 0, seq: 0,
                                       speaker: "Them", tStart: 0, tEnd: 1, text: "foo and bar",
                                       contentHash: "sha256:x")])
        let app = CorrectionDictionary(entries: [
            CorrectionEntry(wrong: "foo", right: "bar"),
            CorrectionEntry(wrong: "bar", right: "baz"),
        ]).makeApplicator()

        _ = try store.recorrectTranscripts(meetingIDs: nil, applicator: app, space: "nomic__v1")
        let after1 = try store.chunks(ids: ["c1"]).first?.text
        let again = try store.recorrectTranscripts(meetingIDs: nil, applicator: app, space: "nomic__v1")
        let after2 = try store.chunks(ids: ["c1"]).first?.text

        #expect(after1 == "baz and baz")   // chain collapsed: foo→baz, bar→baz
        #expect(after2 == after1)          // second sweep changes nothing (idempotent)
        #expect(again.chunks == 0)
    }
}
