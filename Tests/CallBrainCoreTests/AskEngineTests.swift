import Testing
import Foundation
@testable import CallBrainCore

@Suite("AskEngine (retrieve → cited answer)")
struct AskEngineTests {

    private func freshStore() throws -> Store {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("cb-ask-\(UUID().uuidString).sqlite").path
        return try Store(path: path)
    }

    private func sandbox() -> String {
        let p = FileManager.default.temporaryDirectory.appendingPathComponent("cb-ask-sandbox").path
        try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return p
    }

    @Test("empty archive → refuses WITHOUT calling the LLM (no wasted quota)")
    func refusesOnEmpty() async throws {
        let store = try freshStore()
        let search = SearchEngine(store: store, embedder: StubEmbedder(), space: "stub__v1")
        // llm points at a non-existent binary: if ask() tried to call it, the test would throw.
        let llm = ClaudeRunner(executablePath: "/nonexistent/claude", sandboxDir: sandbox())
        let ask = AskEngine(search: search, llm: llm)

        let ans = try await ask.ask("What did Travis say about Render?")
        #expect(ans.status == .noSources)
        #expect(ans.citations.isEmpty)
        #expect(ans.provider == nil)          // never reached the provider
    }

    @Test("hard date-gate: a 'this week' question with no in-window calls refuses WITHOUT the LLM")
    func dateGateRefusesOutOfWindow() async throws {
        let store = try freshStore()
        // One meeting dated well in the past.
        try store.saveMeeting(Meeting(id: "old", title: "Old call", date: "2025-01-02", source: .fireflies),
                              chunks: [Store.ChunkInput(chunkID: "old_c0", meetingID: "old", version: 0, seq: 0,
                                       speaker: "Max", tStart: 0, tEnd: 1, text: "We talked about Render.",
                                       contentHash: "h")])
        let search = SearchEngine(store: store, embedder: StubEmbedder(), space: "stub__v1")
        let llm = ClaudeRunner(executablePath: "/nonexistent/claude", sandboxDir: sandbox())
        let ask = AskEngine(search: search, llm: llm)

        let now = Calendar.current.date(from: DateComponents(year: 2026, month: 6, day: 29))!
        let ans = try await ask.ask("what did we discuss this week", now: now)
        #expect(ans.status == .noSources)
        #expect(ans.provider == nil)                 // never reached the LLM
        #expect(ans.plan?.dateRange?.label == "this week")
        #expect(ans.text.contains("this week"))
    }

    @Test("referencedTags extracts only valid [S#] markers")
    func referencedTags() {
        let t = "Confirmed [S2]. Also [S6] and [S10]. Not [SX], not bare S5, not [s2]."
        #expect(AskEngine.referencedTags(in: t) == ["S2", "S6", "S10"])
        #expect(AskEngine.referencedTags(in: "no tags here").isEmpty)
    }

    // The money shot: real embeddings (Ollama) + real answer (claude), end to end.
    //   CALLBRAIN_LIVE=1 swift test --filter AskEngine
    @Test("LIVE end-to-end: ingest → ask → grounded cited answer",
          .enabled(if: ProcessInfo.processInfo.environment["CALLBRAIN_LIVE"] == "1"))
    func liveEndToEnd() async throws {
        let store = try freshStore()
        let embedder = OllamaEmbedder()
        let space = "nomic__v1"

        let m = Meeting(id: "m1", title: "Travis sync — Render", date: "2026-05-14", source: .fireflies)
        let chunks: [(String, String, String)] = [
            ("c0", "Travis", "On Render, the GPU spot pricing dropped sharply this week, which makes our inference costs much lower."),
            ("c1", "Max",    "Validators stake to secure the network; the economics depend on emissions."),
            ("c2", "JW",     "BGIN and Iceriver shipped new ASIC miners last quarter."),
        ]
        try store.saveMeeting(m, chunks: chunks.map {
            Store.ChunkInput(chunkID: $0.0, meetingID: "m1", version: 0, seq: 0, speaker: $0.1,
                             tStart: 0, tEnd: 1, text: $0.2, contentHash: "blake3:\($0.0)")
        })
        for c in chunks {
            let v = try await embedder.embed([c.2], kind: .document)[0]
            try store.saveEmbedding(chunkID: c.0, space: space, dim: embedder.dim,
                                    modelID: embedder.modelID, vector: v, contentHash: "blake3:\(c.0)")
        }

        let search = SearchEngine(store: store, embedder: embedder, space: space)
        let llm = ClaudeRunner(sandboxDir: sandbox())
        let ask = AskEngine(search: search, llm: llm)

        let ans = try await ask.ask("What did Travis say about Render?")
        #expect(ans.status == .answered)
        #expect(!ans.text.isEmpty)
        #expect(!ans.citations.isEmpty)
        // grounded: the answer should reference Render and cite the Travis chunk
        #expect(ans.text.lowercased().contains("render"))
        #expect(ans.citations.contains { $0.chunkID == "c0" })
        print("LIVE ANSWER:\n\(ans.text)\n--- citations: \(ans.citations.map(\.tag))")
    }
}
