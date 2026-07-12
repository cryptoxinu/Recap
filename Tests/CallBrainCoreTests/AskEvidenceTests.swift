import Testing
import Foundation
@testable import CallBrainCore

/// Perfection plan Task 1.2 — evidence carries meeting name, date, and timestamp, grouped per
/// meeting, so the model can do cross-meeting time-aware synthesis ("In the Jun 29 Morning
/// Sync, …"). Audit finding: today the model gets anonymous chunks and literally cannot.
@Suite("AskEngine evidence assembly (names, dates, timestamps)")
struct AskEvidenceTests {

    /// Captures the exact prompt/system the engine sends; returns a validly-cited answer so the
    /// pipeline completes the answered path.
    final class PromptCapturingLLM: LLMProvider, @unchecked Sendable {
        var lastPrompt: String?
        var lastSystem: String?
        nonisolated var id: ProviderID { .claude }
        func complete(prompt: String, system: String?, model: String, timeout: TimeInterval) async throws -> Completion {
            lastPrompt = prompt; lastSystem = system
            return Completion(text: "Grounded. [S1][S2][S3]", provider: .claude, model: model,
                              usage: TokenUsage(), costUSD: 0)
        }
        func completeJSON(prompt: String, system: String?, schema: String, model: String, timeout: TimeInterval) async throws -> String { "{}" }
    }

    private func seeded() async throws -> (AskEngine, PromptCapturingLLM) {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("cb-evidence-\(UUID().uuidString).sqlite").path
        let store = try Store(path: path)
        let embedder = StubEmbedder()
        let space = "stub__v1"
        let sync = Meeting(id: "mSync", title: "Morning Sync", date: "2026-06-29", source: .fireflies)
        let standup = Meeting(id: "mStand", title: "Ambient Standup", date: "2026-06-25", source: .fireflies)
        // One saveMeeting per meeting — it has full-replace semantics (re-saving a meeting
        // deletes its previous chunks), so chunks must be batched per call.
        let meetings: [(Meeting, [(String, String, Double, String)])] = [
            (sync, [("c1", "Riley", 192, "The GPU pricing on render dropped again."),
                    ("c2", "Alex", 880, "Validators need the new pricing table.")]),
            (standup, [("c3", "Dom", 65, "ASIC hardware pricing changed our math.")]),
        ]
        for (m, rows) in meetings {
            try store.saveMeeting(m, chunks: rows.enumerated().map { i, r in
                Store.ChunkInput(chunkID: r.0, meetingID: m.id, version: 0, seq: i, speaker: r.1,
                                 tStart: r.2, tEnd: r.2 + 30, text: r.3, contentHash: "blake3:\(r.0)")
            })
            for r in rows {
                let v = try await embedder.embed([r.3], kind: .document)[0]
                try store.saveEmbedding(chunkID: r.0, space: space, dim: embedder.dim,
                                        modelID: embedder.modelID, vector: v, contentHash: "blake3:\(r.0)")
            }
        }
        let llm = PromptCapturingLLM()
        let engine = AskEngine(search: SearchEngine(store: store, embedder: embedder, space: space),
                               llm: llm, model: "opus")
        return (engine, llm)
    }

    @Test("evidence is grouped per meeting with == [Title — YYYY-MM-DD] == headers")
    func testEvidenceGroupedPerMeetingWithHeaders() async throws {
        let (engine, llm) = try await seeded()
        let a = try await engine.ask("pricing across validators and asic hardware")
        #expect(a.status == .answered)
        let prompt = try #require(llm.lastPrompt)
        #expect(prompt.contains("== [Morning Sync — 2026-06-29] =="))
        #expect(prompt.contains("== [Ambient Standup — 2026-06-25] =="))
        // Every source line carries its (MM:SS) timestamp.
        #expect(prompt.contains("(03:12) Riley:"))
        #expect(prompt.contains("(14:40) Alex:"))
        #expect(prompt.contains("(01:05) Dom:"))
        // Tags are global and stable — each appears exactly once in the SOURCES block.
        for tag in ["[S1]", "[S2]", "[S3]"] {
            #expect(prompt.components(separatedBy: tag).count == 2, "tag \(tag) should appear once")
        }
    }

    @Test("system prompt teaches cross-meeting attribution and recency preference")
    func testSystemPromptTeachesAttribution() async throws {
        let (engine, llm) = try await seeded()
        _ = try await engine.ask("pricing")
        let system = try #require(llm.lastSystem)
        #expect(system.contains("attribute claims to the call by name"))
        #expect(system.contains("prefer the most recent call"))
    }

    @Test("EvidenceRef carries the chunk's start timestamp")
    func testEvidenceRefCarriesTStart() async throws {
        let (engine, _) = try await seeded()
        let a = try await engine.ask("gpu pricing render")
        let riley = try #require(a.citations.first { $0.speaker == "Riley" })
        #expect(riley.tStart == 192)
    }

    @Test("TimeCode.mmss renders seconds as MM:SS and H:MM:SS")
    func testMMSSFormatsSeconds() {
        #expect(TimeCode.mmss(192) == "03:12")
        #expect(TimeCode.mmss(65) == "01:05")
        #expect(TimeCode.mmss(0) == "00:00")
        #expect(TimeCode.mmss(3725) == "1:02:05")
    }

    @Test("StoredCitation decodes legacy rows without tStart (persisted threads keep working)")
    func testStoredCitationDecodesLegacyRows() throws {
        let legacy = #"{"tag":"S1","chunkID":"c1","meetingID":"m1","speaker":"Dom","text":"hi"}"#
        let c = try JSONDecoder().decode(StoredCitation.self, from: Data(legacy.utf8))
        #expect(c.tStart == nil)
        #expect(c.tag == "S1")
    }
}

/// Task 3.3 — engine streaming: tokens flow to the caller, but the anti-hallucination gate
/// still judges only the FINAL text.
@Suite("AskEngine streaming path")
struct AskStreamingTests {

    final class StreamingCitedLLM: LLMProvider, @unchecked Sendable {
        let finalText: String
        init(finalText: String) { self.finalText = finalText }
        nonisolated var id: ProviderID { .claude }
        func complete(prompt: String, system: String?, model: String, timeout: TimeInterval) async throws -> Completion {
            Completion(text: finalText, provider: .claude, model: model, usage: TokenUsage(), costUSD: 0)
        }
        func completeJSON(prompt: String, system: String?, schema: String, model: String, timeout: TimeInterval) async throws -> String { "{}" }
        func streamComplete(prompt: String, system: String?, model: String, timeout: TimeInterval) -> AsyncThrowingStream<StreamEvent, Error> {
            AsyncThrowingStream { c in
                for word in finalText.split(separator: " ") { c.yield(.delta(String(word) + " ")) }
                c.yield(.done(Completion(text: finalText, provider: .claude, model: model,
                                         usage: TokenUsage(), costUSD: 0)))
                c.finish()
            }
        }
    }

    private func engine(_ llm: any LLMProvider) async throws -> AskEngine {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("cb-stream-ask-\(UUID().uuidString).sqlite").path
        let store = try Store(path: path)
        let embedder = StubEmbedder()
        let m = Meeting(id: "m1", title: "Sync", date: "2026-06-29", source: .fireflies)
        let text = "The GPU pricing dropped again."
        try store.saveMeeting(m, chunks: [Store.ChunkInput(
            chunkID: "c1", meetingID: "m1", version: 0, seq: 0, speaker: "Riley",
            tStart: 0, tEnd: 1, text: text, contentHash: "b:c1")])
        let v = try await embedder.embed([text], kind: .document)[0]
        try store.saveEmbedding(chunkID: "c1", space: "stub__v1", dim: embedder.dim,
                                modelID: embedder.modelID, vector: v, contentHash: "b:c1")
        return AskEngine(search: SearchEngine(store: store, embedder: embedder, space: "stub__v1"),
                         llm: llm, model: "opus")
    }

    @Test("onToken receives deltas before the answered envelope; metrics carry firstTokenMS")
    func testOnTokenReceivesDeltasBeforeAnswered() async throws {
        let e = try await engine(StreamingCitedLLM(finalText: "Pricing dropped. [S1]"))
        let box = TokenBox()
        let a = try await e.ask("gpu pricing", onToken: { t in await box.append(t) })
        #expect(a.status == .answered)
        let tokens = await box.all
        #expect(!tokens.isEmpty)
        #expect(tokens.joined().contains("Pricing"))
        #expect(a.metrics?.firstTokenMS != nil)
    }

    @Test("a streamed answer with no valid citations still refuses (gate unweakened)")
    func testStreamedUncitedAnswerStillRefuses() async throws {
        let e = try await engine(StreamingCitedLLM(finalText: "Confident uncited claims with no tags."))
        let a = try await e.ask("gpu pricing", onToken: { _ in })
        #expect(a.status == .noSources)
        #expect(a.citations.isEmpty)
    }

    actor TokenBox {
        var all: [String] = []
        func append(_ t: String) { all.append(t) }
    }
}

@Suite("Follow-up extraction (Task 4.4)")
struct FollowUpTests {
    @Test("trailing FOLLOW-UPS line is parsed and stripped")
    func testExtract() {
        let (text, ups) = AskEngine.extractFollowUps(
            "Answer body. [S1]\n\nFOLLOW-UPS: What did Riley say? | Status of BitRouter? | Next steps?")
        #expect(text == "Answer body. [S1]")
        #expect(ups == ["What did Riley say?", "Status of BitRouter?", "Next steps?"])
    }
    @Test("no FOLLOW-UPS line → text unchanged, empty list")
    func testAbsent() {
        let (text, ups) = AskEngine.extractFollowUps("Just an answer. [S1]")
        #expect(text == "Just an answer. [S1]")
        #expect(ups.isEmpty)
    }
    @Test("case-insensitive, capped at 3, empties dropped")
    func testTolerant() {
        let (_, ups) = AskEngine.extractFollowUps("A.\nfollow-ups: a? | | b? | c? | d?")
        #expect(ups == ["a?", "b?", "c?"])
    }

    @Test("stripDanglingTags removes fabricated citations, keeps the valid ones (A HIGH)")
    func stripsDanglingCitations() {
        let out = AskEngine.stripDanglingTags("Real point. [S1] Made-up point. [S99]", valid: ["S1"])
        #expect(out == "Real point. [S1] Made-up point.")   // [S99] gone, [S1] kept, spacing clean
        #expect(!out.contains("S99"))
    }
}

/// Task 6.4 — neighboring turns ride along as unnumbered context.
@Suite("Neighboring-turn context")
struct NeighborContextTests {
    @Test("evidence includes (context) lines from adjacent chunks; tags stay on hits only")
    func testNeighborsAppear() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("cb-neigh-\(UUID().uuidString).sqlite").path
        let store = try Store(path: path)
        let embedder = StubEmbedder()
        let m = Meeting(id: "m1", title: "Sync", date: "2026-06-29", source: .fireflies)
        let rows: [(String, Int, String, String)] = [
            ("c0", 0, "Alex", "so what does the roadmap look like for next quarter?"),
            ("c1", 1, "Riley", "The GPU pricing on render dropped again."),
            ("c2", 2, "Alex", "great, lets ship the new table then."),
        ]
        try store.saveMeeting(m, chunks: rows.map { r in
            Store.ChunkInput(chunkID: r.0, meetingID: "m1", version: 0, seq: r.1, speaker: r.2,
                             tStart: Double(r.1 * 30), tEnd: Double(r.1 * 30 + 20), text: r.3,
                             contentHash: "b:\(r.0)")
        })
        // Embed ONLY the middle chunk so retrieval hits just c1.
        let v = try await embedder.embed([rows[1].3], kind: .document)[0]
        try store.saveEmbedding(chunkID: "c1", space: "stub__v1", dim: embedder.dim,
                                modelID: embedder.modelID, vector: v, contentHash: "b:c1")
        let llm = AskEvidenceTests.PromptCapturingLLM()
        let engine = AskEngine(search: SearchEngine(store: store, embedder: embedder, space: "stub__v1"),
                               llm: llm, model: "opus")
        _ = try await engine.ask("render gpu pricing")
        let prompt = try #require(llm.lastPrompt)
        #expect(prompt.contains("(context) Alex: so what does the roadmap look like"))
        #expect(prompt.contains("(context) Alex: great, lets ship"))
        // Context lines carry no tags; the hit keeps its [S1].
        #expect(prompt.contains("[S1]"))
        #expect(!prompt.contains("(context) [S"))
    }
}

/// Task 6.6b — one repair attempt before refusing an untagged-but-substantive answer.
@Suite("Citation repair")
struct CitationRepairTests {
    final class RepairingLLM: LLMProvider, @unchecked Sendable {
        var calls = 0
        nonisolated var id: ProviderID { .claude }
        func complete(prompt: String, system: String?, model: String, timeout: TimeInterval) async throws -> Completion {
            calls += 1
            // First call: a real answer with NO tags. Second (repair): correctly tagged.
            let text = calls == 1
                ? "The GPU pricing on render dropped again this week, which changes the whole cost model for the quarter."
                : "The GPU pricing on render dropped again this week. [S1]"
            return Completion(text: text, provider: .claude, model: model, usage: TokenUsage(), costUSD: 0)
        }
        func completeJSON(prompt: String, system: String?, schema: String, model: String, timeout: TimeInterval) async throws -> String { "{}" }
    }

    @Test("an untagged substantive answer is repaired, not refused")
    func testRepairInsteadOfRefusal() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("cb-repair-\(UUID().uuidString).sqlite").path
        let store = try Store(path: path)
        let embedder = StubEmbedder()
        let m = Meeting(id: "m1", title: "Sync", date: "2026-06-29", source: .fireflies)
        let text = "The GPU pricing on render dropped again."
        try store.saveMeeting(m, chunks: [Store.ChunkInput(
            chunkID: "c1", meetingID: "m1", version: 0, seq: 0, speaker: "Riley",
            tStart: 0, tEnd: 1, text: text, contentHash: "b:c1")])
        let v = try await embedder.embed([text], kind: .document)[0]
        try store.saveEmbedding(chunkID: "c1", space: "stub__v1", dim: embedder.dim,
                                modelID: embedder.modelID, vector: v, contentHash: "b:c1")
        let llm = RepairingLLM()
        let engine = AskEngine(search: SearchEngine(store: store, embedder: embedder, space: "stub__v1"),
                               llm: llm, model: "opus")
        let a = try await engine.ask("gpu pricing render")
        #expect(a.status == .answered)              // repaired, not refused
        #expect(a.citations.map(\.tag) == ["S1"])
        #expect(llm.calls == 2)                     // exactly ONE repair attempt
    }
}

/// Task 6.1 — rewriter gating: fires only for thin follow-ups; junk/nil falls back cleanly.
@Suite("Query rewriting")
struct QueryRewriteTests {
    @Test("a thin follow-up consults the rewriter; a standalone question does not")
    func testRewriterGating() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("cb-rw-\(UUID().uuidString).sqlite").path
        let store = try Store(path: path)
        let embedder = StubEmbedder()
        let m = Meeting(id: "m1", title: "Sync", date: "2026-06-29", source: .fireflies)
        let text = "Validators stake to secure the network."
        try store.saveMeeting(m, chunks: [Store.ChunkInput(
            chunkID: "c1", meetingID: "m1", version: 0, seq: 0, speaker: "Dom",
            tStart: 0, tEnd: 1, text: text, contentHash: "b:c1")])
        let v = try await embedder.embed([text], kind: .document)[0]
        try store.saveEmbedding(chunkID: "c1", space: "stub__v1", dim: embedder.dim,
                                modelID: embedder.modelID, vector: v, contentHash: "b:c1")
        let llm = AskEvidenceTests.PromptCapturingLLM()
        let calls = RewriteCalls()
        let engine = AskEngine(search: SearchEngine(store: store, embedder: embedder, space: "stub__v1"),
                               llm: llm, model: "opus",
                               queryRewriter: { q, _ in await calls.record(q); return "validator staking economics" })
        // Thin anaphoric follow-up → rewriter consulted.
        _ = try await engine.ask("dig into it", history: [.init(role: .user, text: "how do validators work")])
        #expect(await calls.count == 1)
        // Standalone question → heuristic says no enrichment → rewriter NOT consulted.
        _ = try await engine.ask("what are the validator staking economics this quarter")
        #expect(await calls.count == 1)
    }

    actor RewriteCalls {
        var count = 0
        func record(_ q: String) { count += 1 }
    }
}

/// Task 9.4 — local-only mode: cited extractive answer, zero CLI calls.
@Suite("Local-only mode")
struct LocalOnlyTests {
    final class ForbiddenLLM: LLMProvider, @unchecked Sendable {
        nonisolated var id: ProviderID { .claude }
        func complete(prompt: String, system: String?, model: String, timeout: TimeInterval) async throws -> Completion {
            Issue.record("local-only mode must NEVER call the LLM")
            throw LLMError.timedOut(seconds: 0)
        }
        func completeJSON(prompt: String, system: String?, schema: String, model: String, timeout: TimeInterval) async throws -> String { "{}" }
    }

    @Test("answers extractively with citations; the LLM is never touched")
    func testLocalOnlyExtractive() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("cb-localonly-\(UUID().uuidString).sqlite").path
        let store = try Store(path: path)
        let embedder = StubEmbedder()
        let m = Meeting(id: "m1", title: "Sync", date: "2026-06-29", source: .fireflies)
        let text = "The GPU pricing on render dropped again."
        try store.saveMeeting(m, chunks: [Store.ChunkInput(
            chunkID: "c1", meetingID: "m1", version: 0, seq: 0, speaker: "Riley",
            tStart: 30, tEnd: 40, text: text, contentHash: "b:c1")])
        let v = try await embedder.embed([text], kind: .document)[0]
        try store.saveEmbedding(chunkID: "c1", space: "stub__v1", dim: embedder.dim,
                                modelID: embedder.modelID, vector: v, contentHash: "b:c1")
        let engine = AskEngine(search: SearchEngine(store: store, embedder: embedder, space: "stub__v1"),
                               llm: ForbiddenLLM(), model: "opus", localOnly: true)
        let a = try await engine.ask("gpu pricing render")
        #expect(a.status == .answered)
        #expect(a.text.contains("Local-only mode"))
        #expect(a.text.contains("[S1]"))
        #expect(a.citations.first?.chunkID == "c1")
        #expect(a.model == "local-extractive")
    }
}
