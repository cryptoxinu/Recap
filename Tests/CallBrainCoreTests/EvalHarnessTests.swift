import Testing
import Foundation
@testable import CallBrainCore

@Suite("Eval harness (anti-hallucination invariants)")
struct EvalHarnessTests {

    private func sandbox() -> String {
        let p = FileManager.default.temporaryDirectory.appendingPathComponent("cb-eval-sandbox").path
        try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return p
    }

    /// A small golden corpus seeded into a fresh store: two meetings on known dates with known content.
    private func seedCorpus(_ store: Store, embedder: any Embedder, space: String) async throws {
        let meetings: [(String, String, [(String, String, String)])] = [
            ("m_render", "2026-06-29", [("c_render", "Travis", "On Render, the GPU spot pricing dropped sharply this week, lowering inference cost.")]),
            ("m_val", "2025-02-10", [("c_val", "Max", "Validators stake to secure the network; emissions drive the economics.")]),
        ]
        for (mid, date, chunks) in meetings {
            try store.saveMeeting(Meeting(id: mid, title: mid, date: date, source: .fireflies),
                chunks: chunks.map { Store.ChunkInput(chunkID: $0.0, meetingID: mid, version: 0, seq: 0,
                    speaker: $0.1, tStart: 0, tEnd: 1, text: $0.2, contentHash: "h_\($0.0)") })
            for c in chunks {
                let v = try await embedder.embed([c.2], kind: .document)[0]
                try store.saveEmbedding(chunkID: c.0, space: space, dim: embedder.dim,
                                        modelID: embedder.modelID, vector: v, contentHash: "h_\(c.0)")
            }
        }
    }

    private let thisWeek = Calendar.current.date(from: DateComponents(year: 2026, month: 6, day: 29))!

    /// Deterministic invariants — NO LLM needed (refusals + empty-window date-gates).
    @Test("deterministic eval: refusals + date-gating violations = 0")
    func deterministicInvariants() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("cb-eval-\(UUID().uuidString).sqlite").path
        let store = try Store(path: path)
        let embedder = StubEmbedder()
        try await seedCorpus(store, embedder: embedder, space: "stub__v1")
        let search = SearchEngine(store: store, embedder: embedder, space: "stub__v1")
        // nonexistent binary → if any case reached the LLM, it would error and fail the eval.
        let ask = AskEngine(search: search, llm: ClaudeRunner(executablePath: "/nonexistent", sandboxDir: sandbox()))

        // The deterministic guarantee is the HARD date-gate: a time-scoped question whose window has no
        // meetings REFUSES before any LLM call (and still resolves the correct window label). Grounded-
        // answer refusal on irrelevant-but-present evidence is the LLM's job → the live eval below.
        let emptyWeek = Calendar.current.date(from: DateComponents(year: 2026, month: 8, day: 15))!
        let cases = [
            // "last month" of 2026-06-29 = May 2026 → no meetings → refuse + correct window.
            EvalCase(id: "gate-lastmonth", question: "what happened last month", now: thisWeek,
                     expects: [.refuses, .dateScoped(label: "last month")]),
            // "yesterday" of 2026-06-29 = 06-28 → no meeting (render is 06-29) → refuse.
            EvalCase(id: "gate-yesterday", question: "what was said yesterday", now: thisWeek,
                     expects: [.refuses, .dateScoped(label: "yesterday")]),
            // "this week" of 2026-08-15 → empty window → refuse + label.
            EvalCase(id: "gate-thisweek-empty", question: "what did we cover this week", now: emptyWeek,
                     expects: [.refuses, .dateScoped(label: "this week")]),
        ]
        let results = await EvalHarness(ask: ask).run(cases)
        if !results.allPassed { Issue.record("\(results.report)") }
        #expect(results.allPassed)
    }

    /// Full grounded-answer eval (citation precision + no out-of-window leakage) — needs a live provider.
    @Test("LIVE eval: grounded answers cite only real, in-scope chunks",
          .enabled(if: ProcessInfo.processInfo.environment["CALLBRAIN_LIVE"] == "1"))
    func liveGrounding() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("cb-eval-live-\(UUID().uuidString).sqlite").path
        let store = try Store(path: path)
        let embedder = OllamaEmbedder()
        try await seedCorpus(store, embedder: embedder, space: "nomic__v1")
        let search = SearchEngine(store: store, embedder: embedder, space: "nomic__v1")
        let ask = AskEngine(search: search, llm: ClaudeRunner(sandboxDir: sandbox()))

        let cases = [
            EvalCase(id: "render-answer", question: "What did Travis say about Render?",
                     expects: [.answers, .citesOnlyMeetings(["m_render"])]),
            EvalCase(id: "render-thisweek", question: "What did we discuss about Render this week?", now: thisWeek,
                     expects: [.answers, .dateScoped(label: "this week"), .citesOnlyMeetings(["m_render"])]),
            EvalCase(id: "refuse-offtopic", question: "What is our policy on remote work?",
                     expects: [.refuses]),
        ]
        let results = await EvalHarness(ask: ask).run(cases)
        print(results.report)
        #expect(results.allPassed)
    }
}
