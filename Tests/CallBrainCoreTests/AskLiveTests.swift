import Testing
import Foundation
@testable import CallBrainCore

@Suite("AskLive")
struct AskLiveTests {
    @Test("askLive streams deltas and returns authoritative done text")
    func testAskLiveStreamsDeltasAndReturnsDoneText() async throws {
        let llm = FakeLLM(
            streamEvents: [
                .ready,
                .delta("They said "),
                .delta("pricing changed."),
                .done(Self.completion("Final answer from done.")),
            ],
            completion: Self.completion("buffered")
        )
        let engine = try Self.engine(llm: llm)
        let box = TokenBox()

        let answer = try await engine.askLive(
            "what did they say?",
            transcript: "Them: Pricing changed this week.",
            onToken: { delta in await box.append(delta) }
        )

        #expect(await box.all == ["They said ", "pricing changed."])
        #expect(answer == "Final answer from done.")
    }

    @Test("askLive does not use retrieval")
    func testAskLiveDoesNotUseRetrieval() async throws {
        let llm = FakeLLM(streamEvents: [], completion: Self.completion("Live answer."))
        let engine = try Self.engine(llm: llm, embedder: TrapEmbedder())

        let answer = try await engine.askLive(
            "summarize this",
            transcript: "You: Should we ask about margins?\nThem: Yes, margins changed."
        )

        #expect(answer == "Live answer.")
    }

    private static let longTranscript =
        "Them: Our margins changed this quarter because raw material costs went up about 12 percent and we haven't repriced. You: How are you thinking about the timeline for a price increase?"

    @Test("suggestQuestions parses one-per-line questions")
    func testSuggestQuestionsParsesLines() async throws {
        let llm = FakeLLM(streamEvents: [],
                          completion: Self.completion("Ask about margins?\nConfirm timeline?\nWho owns it?"))
        let engine = try Self.engine(llm: llm)

        let questions = await engine.suggestQuestions(from: Self.longTranscript)

        #expect(questions == ["Ask about margins?", "Confirm timeline?", "Who owns it?"])
    }

    @Test("suggestQuestions drops placeholder echoes (q1?/pipe template) and gates a near-empty call")
    func testSuggestQuestionsRejectsPlaceholders() async throws {
        let junk = FakeLLM(streamEvents: [], completion: Self.completion("FOLLOW-UPS: q1? | q2? | q3?"))
        #expect(await (try Self.engine(llm: junk)).suggestQuestions(from: Self.longTranscript).isEmpty)
        // A near-empty transcript never even asks the model.
        let real = FakeLLM(streamEvents: [], completion: Self.completion("Real question?"))
        #expect(await (try Self.engine(llm: real)).suggestQuestions(from: "Them: hi").isEmpty)
    }

    @Test("suggestQuestions returns empty on provider failure")
    func testSuggestQuestionsReturnsEmptyOnFailure() async throws {
        let llm = FakeLLM(streamEvents: [], completion: Self.completion("unused"), completeError: LLMError.launchFailed("down"))
        let engine = try Self.engine(llm: llm)

        let questions = await engine.suggestQuestions(from: Self.longTranscript)

        #expect(questions.isEmpty)
    }

    @Test("askLiveFast streams via the FAST provider, not the smart CLI")
    func testAskLiveFastUsesFastProvider() async throws {
        let smart = FakeLLM(streamEvents: [.done(Self.completion("SMART"))], completion: Self.completion("SMART"))
        let fast = FakeLLM(streamEvents: [.delta("FA"), .delta("ST"), .done(Self.completion("FAST"))],
                           completion: Self.completion("FAST"))
        let engine = try Self.engine(llm: smart, fastLLM: fast)
        let box = TokenBox()

        #expect(engine.hasFastLane)
        let answer = try await engine.askLiveFast(
            "recap?", transcript: "Them: pricing changed.",
            onToken: { d in await box.append(d) })

        #expect(answer == "FAST")
        #expect(await box.all == ["FA", "ST"])
    }

    @Test("askLiveFast throws when no fast lane is configured (caller degrades to Smart-only)")
    func testAskLiveFastThrowsWithoutFastLane() async throws {
        let engine = try Self.engine(llm: FakeLLM(streamEvents: [], completion: Self.completion("x")))
        #expect(!engine.hasFastLane)
        await #expect(throws: LLMError.self) {
            _ = try await engine.askLiveFast("q", transcript: "Them: hi")
        }
    }

    @Test("summarizeLive parses bullets and routes to the fast lane")
    func testSummarizeLiveParsesBulletsViaFastLane() async throws {
        let smart = TrapLLM()   // must not be touched when a fast lane exists
        let fast = FakeLLM(streamEvents: [], completion: Self.completion(
            "- Decided to ship Friday\n- Budget is $40k\n* Bob owns the migration\n"))
        let engine = try Self.engine(llm: smart, fastLLM: fast)

        let notes = await engine.summarizeLive(transcript: "Them: We ship Friday, budget 40k.")

        #expect(notes.map(\.text) == ["Decided to ship Friday", "Budget is $40k", "Bob owns the migration"])
        #expect(notes.allSatisfy { !$0.isHeader })   // no template → plain bullets
    }

    @Test("summarizeLive with template instructions produces section HEADERS + bullets")
    func testSummarizeLiveSectioned() async throws {
        let fast = FakeLLM(streamEvents: [], completion: Self.completion(
            "Pain points\n- Costs up 12%\nNext steps\n- Reprice next week"))
        let engine = try Self.engine(llm: FakeLLM(streamEvents: [], completion: Self.completion("x")), fastLLM: fast)

        let notes = await engine.summarizeLive(transcript: "Them: costs rose.", instructions: "Pain points; Next steps")

        #expect(notes.count == 4)
        #expect(notes[0] == NoteLine(text: "Pain points", isHeader: true))
        #expect(notes[1] == NoteLine(text: "Costs up 12%", isHeader: false))
        #expect(notes[2] == NoteLine(text: "Next steps", isHeader: true))
        #expect(notes[3] == NoteLine(text: "Reprice next week", isHeader: false))
    }

    @Test("mineCorrections parses JSON, drops self-corrections + terms not in the transcript, dedupes")
    func testMineCorrections() async throws {
        let llm = FakeLLM(streamEvents: [], completion: Self.completion("""
        {"corrections":[
          {"heard":"aetherium","shouldBe":"Ethereum","reason":"crypto term"},
          {"heard":"same","shouldBe":"same","reason":"self — drop"},
          {"heard":"notintranscript","shouldBe":"Foo","reason":"absent — drop"},
          {"heard":"aetherium","shouldBe":"Ethereum","reason":"dup — drop"}
        ]}
        """))
        let engine = try Self.engine(llm: llm)

        let mined = await engine.mineCorrections(transcript: "We discussed aetherium and same today.",
                                                 glossary: ["Ethereum"])

        #expect(mined.count == 1)
        #expect(mined[0].heard == "aetherium")
        #expect(mined[0].shouldBe == "Ethereum")
    }

    @Test("mineCorrections requires whole-token presence + dedupes by heard — audit MED")
    func testMineCorrectionsTokenBoundaryAndHeardDedupe() async throws {
        let llm = FakeLLM(streamEvents: [], completion: Self.completion("""
        {"corrections":[
          {"heard":"SOL","shouldBe":"$SOL","reason":"substring of 'sold' — must be dropped"},
          {"heard":"aetherium","shouldBe":"Ethereum","reason":"ok"},
          {"heard":"aetherium","shouldBe":"Etherium Classic","reason":"same heard, conflicting — drop"}
        ]}
        """))
        let engine = try Self.engine(llm: llm)

        let mined = await engine.mineCorrections(transcript: "We sold nothing but aetherium mooned.",
                                                 glossary: [])

        #expect(mined.count == 1)                 // "SOL" dropped (only "sold" present); dup heard dropped
        #expect(mined[0].heard == "aetherium")
        #expect(mined[0].shouldBe == "Ethereum")  // first same-heard wins
    }

    @Test("mineCorrections returns [] on empty transcript or provider failure")
    func testMineCorrectionsEmpty() async throws {
        let ok = try Self.engine(llm: FakeLLM(streamEvents: [], completion: Self.completion(#"{"corrections":[]}"#)))
        #expect(await ok.mineCorrections(transcript: "  ", glossary: []).isEmpty)
    }

    @Test("parseBullets strips -, *, •, and numbered prefixes and caps at 6")
    func testParseBullets() {
        let out = AskEngine.parseBullets("""
        - one
        * two
        • three
        1. four
        2) five

        - six
        - seven
        """)
        #expect(out == ["one", "two", "three", "four", "five", "six"])
    }

    @Test("suggestQuestions routes to the fast lane when configured (no CLI spawn)")
    func testSuggestQuestionsPrefersFastLane() async throws {
        // The smart CLI provider is a TRAP: if suggestions touch it, the test fails.
        let smart = TrapLLM()
        let fast = FakeLLM(streamEvents: [],
                           completion: Self.completion("Ask margins?\nTimeline?\nWho owns it?"))
        let engine = try Self.engine(llm: smart, fastLLM: fast)

        let questions = await engine.suggestQuestions(from: Self.longTranscript)

        #expect(questions == ["Ask margins?", "Timeline?", "Who owns it?"])
    }

    private static func engine(llm: any LLMProvider, fastLLM: (any LLMProvider)? = nil,
                               embedder: any Embedder = StubEmbedder()) throws -> AskEngine {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("cb-ask-live-\(UUID().uuidString).sqlite").path
        let store = try Store(path: path)
        let search = SearchEngine(store: store, embedder: embedder, space: "stub__v1")
        return AskEngine(search: search, llm: llm, model: "opus", fastLLM: fastLLM)
    }

    /// A smart-lane provider that must NEVER be called (used to prove suggestions route to the fast lane).
    final class TrapLLM: LLMProvider, @unchecked Sendable {
        nonisolated var id: ProviderID { .claude }
        func complete(prompt: String, system: String?, model: String, timeout: TimeInterval) async throws -> Completion {
            Issue.record("suggestQuestions must not call the smart CLI when a fast lane exists")
            return Completion(text: "", provider: .claude, model: "sonnet", usage: TokenUsage(), costUSD: 0)
        }
        func completeJSON(prompt: String, system: String?, schema: String, model: String, timeout: TimeInterval) async throws -> String { "{}" }
        func streamComplete(prompt: String, system: String?, model: String, timeout: TimeInterval) -> AsyncThrowingStream<StreamEvent, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    private static func completion(_ text: String) -> Completion {
        Completion(text: text, provider: .claude, model: "sonnet", usage: TokenUsage(), costUSD: 0)
    }

    final class FakeLLM: LLMProvider, @unchecked Sendable {
        let streamEvents: [StreamEvent]
        let completion: Completion
        let completeError: (any Error)?

        init(streamEvents: [StreamEvent], completion: Completion, completeError: (any Error)? = nil) {
            self.streamEvents = streamEvents
            self.completion = completion
            self.completeError = completeError
        }

        nonisolated var id: ProviderID { .claude }

        func complete(prompt: String, system: String?, model: String, timeout: TimeInterval) async throws -> Completion {
            if let completeError { throw completeError }
            return completion
        }

        func completeJSON(prompt: String, system: String?, schema: String, model: String, timeout: TimeInterval) async throws -> String {
            if let completeError { throw completeError }
            return completion.text   // let tests feed JSON via `completion`
        }

        func streamComplete(prompt: String, system: String?, model: String, timeout: TimeInterval) -> AsyncThrowingStream<StreamEvent, Error> {
            AsyncThrowingStream { continuation in
                for event in streamEvents { continuation.yield(event) }
                continuation.finish()
            }
        }
    }

    struct TrapEmbedder: Embedder {
        let modelID = "trap"
        let dim = 1

        func embed(_ texts: [String], kind: EmbedKind) async throws -> [[Float]] {
            Issue.record("askLive must not call retrieval or embedding")
            return []
        }
    }

    actor TokenBox {
        var all: [String] = []
        func append(_ delta: String) {
            all = all + [delta]
        }
    }
}
