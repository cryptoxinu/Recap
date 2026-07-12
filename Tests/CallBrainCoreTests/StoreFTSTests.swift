import Testing
import Foundation
@testable import CallBrainCore

/// Perfection plan Task 1.1 — the dead-keyword-lane fix. Today sanitizeFTS quotes every token
/// and space-joins them, which FTS5 reads as implicit AND: natural questions match ~nothing and
/// "hybrid" retrieval is functionally vector-only (confirmed audit finding, Store.swift:1047).
@Suite("Store.sanitizeFTS (stopword-strip + OR-join)")
struct StoreFTSTests {

    private func seededStore() throws -> Store {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("cb-fts-\(UUID().uuidString).sqlite").path
        let store = try Store(path: path)
        let m = Meeting(id: "m1", title: "billing sync", date: "2026-06-20", source: .fireflies)
        try store.saveMeeting(m, chunks: [Store.ChunkInput(
            chunkID: "c1", meetingID: "m1", version: 0, seq: 0, speaker: "Riley",
            tStart: 0, tEnd: 1, text: "Riley said the billing pipeline ships Friday",
            contentHash: "blake3:c1")])
        return store
    }

    @Test("a natural-language question matches via OR (dies under implicit-AND)")
    func testNaturalQuestionMatchesViaOR() throws {
        let store = try seededStore()
        let hits = try store.keywordSearch("what did riley say about billing", limit: 10)
        #expect(!hits.isEmpty)
    }

    @Test("stopwords are dropped from the MATCH expression")
    func testStopwordsAreDropped() {
        let q = Store.sanitizeFTS("what did riley say about the billing")
        #expect(!q.contains("\"what\""))
        #expect(!q.contains("\"the\""))
        #expect(q.contains("\"riley\""))
        #expect(q.contains("\"billing\""))
    }

    @Test("user-quoted phrases survive verbatim as phrase queries")
    func testQuotedPhrasePreserved() {
        let q = Store.sanitizeFTS(#"status of "proof of logits""#)
        #expect(q.contains("\"proof of logits\""))
    }

    @Test("an all-stopword question falls back to its original tokens, never an empty MATCH")
    func testAllStopwordsFallsBackToOriginalTokens() {
        #expect(!Store.sanitizeFTS("what did they say").isEmpty)
    }

    @Test("tokens are OR-joined so BM25 ranks multi-term matches, not AND-filtered")
    func testTokensAreORJoined() {
        let q = Store.sanitizeFTS("riley billing pipeline")
        #expect(q.contains(" OR "))
        #expect(!q.contains(" AND "))
    }

    @Test("punctuation and FTS operators in raw input cannot break the query")
    func testOperatorInjectionStaysSafe() throws {
        let store = try seededStore()
        // NEAR/NOT/parens/asterisks must be neutralized by quoting, not crash the MATCH.
        let hits = try store.keywordSearch(#"billing NEAR(pipeline) NOT "ships" *"#, limit: 10)
        _ = hits   // no throw = pass; ranking is BM25's business
    }

    // MARK: Task 2.0 — FTS triggers must be keyed on chunk_id, not rowid (judge BLOCKER)

    /// VACUUM INTO renumbers transcript_chunks rowids (TEXT PK → implicit rowid) while the
    /// standalone chunks_fts keeps its own — so on a RESTORED store, rowid-keyed AD/AU triggers
    /// delete the WRONG fts rows. saveMeeting's full-replace fires exactly that path. This test
    /// creates a rowid gap, backs up, restores, edits — and search must stay truthful.
    @Test("a restored backup survives a meeting re-save without FTS desync")
    func testRestoredBackupSurvivesChunkUpdate() async throws {
        let srcPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("cb-rekey-src-\(UUID().uuidString).sqlite").path
        let store = try Store(path: srcPath)
        func meeting(_ id: String, _ title: String, _ text: String) throws {
            let m = Meeting(id: id, title: title, date: "2026-06-20", source: .fireflies)
            try store.saveMeeting(m, chunks: [Store.ChunkInput(
                chunkID: "c-\(id)", meetingID: id, version: 0, seq: 0, speaker: "S",
                tStart: 0, tEnd: 1, text: text, contentHash: "blake3:\(id)")])
        }
        try meeting("m1", "First", "alpha bravo topic")
        try meeting("m2", "Second", "charlie delta topic")
        try meeting("m3", "Third", "echo foxtrot topic")
        try store.deleteMeeting(id: "m1")            // rowid gap → VACUUM renumbers survivors

        let backupURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cb-rekey-bak-\(UUID().uuidString).sqlite")
        try store.backup(to: backupURL)

        let restored = try Store(path: backupURL.path)
        // Re-save m2 with new text — full-replace fires the AD trigger on the restored store.
        let m2 = Meeting(id: "m2", title: "Second", date: "2026-06-20", source: .fireflies)
        try restored.saveMeeting(m2, chunks: [Store.ChunkInput(
            chunkID: "c-m2b", meetingID: "m2", version: 0, seq: 0, speaker: "S",
            tStart: 0, tEnd: 1, text: "golf hotel topic", contentHash: "blake3:m2b")])

        #expect(try restored.keywordSearch("golf", limit: 10).count == 1)      // new text findable
        #expect(try restored.keywordSearch("charlie", limit: 10).isEmpty)      // old text truly gone
        #expect(try restored.keywordSearch("echo", limit: 10).count == 1)      // bystander intact
    }
}
