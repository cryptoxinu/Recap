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

        let ans = try await ask.ask("What did Riley say about Render?")
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
                                       speaker: "Dom", tStart: 0, tEnd: 1, text: "We talked about Render.",
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

    @Test("ask(inMeeting:) on a meeting with no chunks refuses WITHOUT the LLM")
    func meetingScopedEmptyRefuses() async throws {
        let store = try freshStore()
        let search = SearchEngine(store: store, embedder: StubEmbedder(), space: "stub__v1")
        let ask = AskEngine(search: search, llm: ClaudeRunner(executablePath: "/nonexistent", sandboxDir: sandbox()))
        let ans = try await ask.ask("summarize this call", inMeeting: "nope")
        #expect(ans.status == .noSources)
        #expect(ans.provider == nil)
    }

    @Test("ask(inMeetings:) with no indexed content across the set refuses WITHOUT the LLM (v4 prep)")
    func multiMeetingScopedEmptyRefuses() async throws {
        let store = try freshStore()
        let search = SearchEngine(store: store, embedder: StubEmbedder(), space: "stub__v1")
        let ask = AskEngine(search: search, llm: ClaudeRunner(executablePath: "/nonexistent", sandboxDir: sandbox()))
        let ans = try await ask.ask("prep me for this call", inMeetings: ["a", "b", "c"])
        #expect(ans.status == .noSources)
        #expect(ans.provider == nil)          // never spent quota on a first-ever meeting
    }

    @Test("referencedTags extracts only valid [S#] markers")
    func referencedTags() {
        let t = "Confirmed [S2]. Also [S6] and [S10]. Not [SX], not bare S5, not [s2]."
        #expect(AskEngine.referencedTags(in: t) == ["S2", "S6", "S10"])
        #expect(AskEngine.referencedTags(in: "no tags here").isEmpty)
    }

    @Test("retrievalQuery folds the prior question into a THIN follow-up, leaves a full question alone")
    func retrievalQueryFollowUp() {
        let hist = [AskEngine.Turn(role: .user, text: "What did Riley say about Render pricing?"),
                    AskEngine.Turn(role: .assistant, text: "He said spot prices dropped [S1].",
                                   retrievalHint: "S1 Riley Render spot pricing dropped")]
        // thin follow-up → enriched with the last user question
        let thin = AskEngine.retrievalQuery("what about Dom?", history: hist)
        #expect(thin.contains("Render pricing"))
        #expect(thin.contains("what about Dom?"))
        #expect(thin.contains("spot prices dropped"))
        // substantive question → stands on its own
        let full = AskEngine.retrievalQuery("What were the BitRouter integration blockers this week?", history: hist)
        #expect(full == "What were the BitRouter integration blockers this week?")
        // anaphor in an otherwise long-ish question still pulls prior context (SME M6)
        let anaphor = AskEngine.retrievalQuery("Did they ever resolve that whole pricing thing?", history: hist)
        #expect(anaphor.contains("Render pricing"))
        #expect(anaphor.contains("S1 Riley Render"))
        // no history → unchanged
        #expect(AskEngine.retrievalQuery("anything", history: []) == "anything")
    }

    @Test("historyBlock is bounded (last 6 turns) and labels roles")
    func historyBlockBounds() {
        let turns = (0..<10).map { AskEngine.Turn(role: $0 % 2 == 0 ? .user : .assistant, text: "turn \($0)") }
        let block = AskEngine.historyBlock(turns)
        #expect(block.contains("turn 9"))
        #expect(!block.contains("turn 3"))        // older than the last 6 → dropped
        #expect(block.contains("User:") && block.contains("Assistant:"))
        #expect(AskEngine.historyBlock([]).isEmpty)
    }

    @Test("looksLikeResearch fires on explicit web cues only")
    func researchIntent() {
        #expect(AskEngine.looksLikeResearch("Research Render online and relate it to our calls"))
        #expect(AskEngine.looksLikeResearch("look this up on the web"))
        #expect(AskEngine.looksLikeResearch("search online for OpenRouter pricing"))
        #expect(!AskEngine.looksLikeResearch("What did we decide about pricing?"))
        #expect(!AskEngine.looksLikeResearch("Summarize the morning sync"))
    }

    // The money shot: real embeddings (Ollama) + real answer (claude), end to end.
    //   CALLBRAIN_LIVE=1 swift test --filter AskEngine
    @Test("LIVE end-to-end: ingest → ask → grounded cited answer",
          .enabled(if: ProcessInfo.processInfo.environment["CALLBRAIN_LIVE"] == "1"))
    func liveEndToEnd() async throws {
        let store = try freshStore()
        let embedder = OllamaEmbedder()
        let space = "nomic__v1"

        let m = Meeting(id: "m1", title: "Riley sync — Render", date: "2026-05-14", source: .fireflies)
        let chunks: [(String, String, String)] = [
            ("c0", "Riley", "On Render, the GPU spot pricing dropped sharply this week, which makes our inference costs much lower."),
            ("c1", "Dom",    "Validators stake to secure the network; the economics depend on emissions."),
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

        let ans = try await ask.ask("What did Riley say about Render?")
        #expect(ans.status == .answered)
        #expect(!ans.text.isEmpty)
        #expect(!ans.citations.isEmpty)
        // grounded: the answer should reference Render and cite the Riley chunk
        #expect(ans.text.lowercased().contains("render"))
        #expect(ans.citations.contains { $0.chunkID == "c0" })
        print("LIVE ANSWER:\n\(ans.text)\n--- citations: \(ans.citations.map(\.tag))")
    }

    @Test("retrieval breadth: autoTopK pulls enough passages to cover a multi-call corpus (founder 2026-07-01)")
    func autoTopKBreadth() {
        // Raised from 12/18 so cross-call "what did everyone ask me to do" doesn't miss content.
        #expect(AskEngine.autoTopK(.actionItems) >= 24)
        #expect(AskEngine.autoTopK(.person) >= 24)
        #expect(AskEngine.autoTopK(.sourceFind) >= 24)
        #expect(AskEngine.autoTopK(.general) >= 32)
        #expect(AskEngine.autoTopK(.technical) >= 32)
        #expect(AskEngine.autoTopK(.timeScoped) >= 32)
    }

    @Test("person questions hard-scope to that speaker so Dom's Slackbot points are not drowned out")
    func personQuestionHardScopesSpeaker() async throws {
        let store = try freshStore()
        let embedder = StubEmbedder()
        let space = "stub__v1"
        let meeting = Meeting(id: "m1", title: "Founder sync", date: "2026-07-06", source: .fireflies)
        let chunks: [(String, String, String)] = [
            ("c_travis", "Riley", "Riley said Render pricing and validator economics need a cleanup."),
            ("c_max_bot", "Dom", "Dom said add a Slackbot so follow-ups do not get lost."),
            ("c_max_projects", "Dom", "Dom said the BitRouter and Proof of Logits projects need named owners."),
        ]
        try store.saveMeeting(meeting, chunks: chunks.enumerated().map { i, row in
            Store.ChunkInput(chunkID: row.0, meetingID: meeting.id, version: 0, seq: i,
                             speaker: row.1, tStart: Double(i), tEnd: Double(i + 1),
                             text: row.2, contentHash: "b:\(row.0)")
        })
        for row in chunks {
            let v = try await embedder.embed([row.2], kind: .document)[0]
            try store.saveEmbedding(chunkID: row.0, space: space, dim: embedder.dim,
                                    modelID: embedder.modelID, vector: v, contentHash: "b:\(row.0)")
        }
        let llm = AskEvidenceTests.PromptCapturingLLM()
        let ask = AskEngine(search: SearchEngine(store: store, embedder: embedder, space: space), llm: llm)

        _ = try await ask.ask("what was everything Dom said")
        let prompt = try #require(llm.lastPrompt)
        #expect(prompt.contains("Dom: Dom said add a Slackbot"))
        #expect(prompt.contains("Dom: Dom said the BitRouter"))
        #expect(!prompt.contains("Riley: Riley said Render pricing"))
    }

    @Test("named action-item questions hard-scope retrieval to the named speaker")
    func namedActionItemHardScopesSpeaker() async throws {
        let store = try freshStore()
        let embedder = StubEmbedder()
        let space = "stub__v1"
        let meeting = Meeting(id: "m1", title: "Launch sync", date: "2026-07-06", source: .fireflies)
        let chunks: [(String, String, String)] = [
            ("c_travis", "Riley", "Riley asked the whole launch team to update pricing docs before Friday."),
            ("c_ghazal", "Priya", "Priya asked me to own the launch checklist and send the partner update."),
            ("c_max", "Dom", "Dom mentioned launch timing but did not assign anything."),
        ]
        try store.saveMeeting(meeting, chunks: chunks.enumerated().map { i, row in
            Store.ChunkInput(chunkID: row.0, meetingID: meeting.id, version: 0, seq: i,
                             speaker: row.1, tStart: Double(i), tEnd: Double(i + 1),
                             text: row.2, contentHash: "b:\(row.0)")
        })
        for row in chunks {
            let v = try await embedder.embed([row.2], kind: .document)[0]
            try store.saveEmbedding(chunkID: row.0, space: space, dim: embedder.dim,
                                    modelID: embedder.modelID, vector: v, contentHash: "b:\(row.0)")
        }
        let llm = AskEvidenceTests.PromptCapturingLLM()
        let ask = AskEngine(search: SearchEngine(store: store, embedder: embedder, space: space), llm: llm)

        _ = try await ask.ask("what did Priya ask me to do about launch")
        let prompt = try #require(llm.lastPrompt)
        #expect(prompt.contains("Priya: Priya asked me to own the launch checklist"))
        #expect(!prompt.contains("Riley: Riley asked the whole launch team"))
        #expect(!prompt.contains("Dom: Dom mentioned launch timing"))
    }

    @Test("explicit all-calls named action query covers the full speaker corpus, not the old 24-source cap")
    func exhaustiveNamedActionQuestionCoversAllSpeakerCalls() async throws {
        let store = try freshStore()
        let embedder = StubEmbedder()
        let space = "stub__v1"
        var allRows: [(String, String)] = []
        for i in 1...30 {
            let suffix = String(format: "%02d", i)
            let meeting = Meeting(id: "max_action_\(suffix)", title: "Dom Action \(suffix)",
                                  date: "2026-07-\(String(format: "%02d", min(i, 28)))",
                                  source: .fireflies)
            let maxID = "c_max_\(suffix)"
            let travisID = "c_travis_\(suffix)"
            let maxText = "Dom asked me to keep track of Dom action item \(suffix) and follow up with Riley."
            let travisText = "Riley asked the team to keep track of Riley distractor item \(suffix)."
            let chunks = [
                Store.ChunkInput(chunkID: maxID, meetingID: meeting.id, version: 0, seq: 0,
                                 speaker: "Dom", tStart: 10, tEnd: 20, text: maxText,
                                 contentHash: "b:\(maxID)"),
                Store.ChunkInput(chunkID: travisID, meetingID: meeting.id, version: 0, seq: 1,
                                 speaker: "Riley", tStart: 21, tEnd: 30, text: travisText,
                                 contentHash: "b:\(travisID)"),
            ]
            try store.saveMeeting(meeting, chunks: chunks)
            allRows.append((maxID, maxText))
            allRows.append((travisID, travisText))
        }
        for row in allRows {
            let v = try await embedder.embed([row.1], kind: .document)[0]
            try store.saveEmbedding(chunkID: row.0, space: space, dim: embedder.dim,
                                    modelID: embedder.modelID, vector: v, contentHash: "b:\(row.0)")
        }
        let llm = AskEvidenceTests.PromptCapturingLLM()
        let ask = AskEngine(search: SearchEngine(store: store, embedder: embedder, space: space), llm: llm)

        let answer = try await ask.ask("What was everything dom asked me todo and keep track of across all calls?")
        let prompt = try #require(llm.lastPrompt)

        #expect(answer.plan?.mode == .actionItems)
        #expect(answer.plan?.speaker == "Dom")
        #expect(answer.plan?.exhaustive == true)
        for i in 1...30 {
            #expect(prompt.contains("Dom action item \(String(format: "%02d", i))"))
        }
        #expect(!prompt.contains("Riley distractor item"))
    }

    @Test("source-find questions return the matching call moments verbatim without spending an LLM call")
    func sourceFindReturnsVerbatimMoments() async throws {
        let store = try freshStore()
        let embedder = StubEmbedder()
        let space = "stub__v1"
        let meeting = Meeting(id: "morning", title: "2026-07-02 morning sync", date: "2026-07-02", source: .gmeetLocal)
        let chunks: [(String, String, String)] = [
            ("c_notes", "Gemini Notes", "Summary: action metadata and traffic throughput comparisons were discussed."),
            ("c_max_track", "Dominic Vance", "Sam, every day there are three or four of these partner items where we need someone hounding us or the opposite party so BitRouter and Arena.dev do not fall off the map."),
            ("c_max_plate", "Dominic Vance", "Sam, if I could add something onto your plate, work with Riley on the verification and KYC referral program."),
            ("c_chris", "Chris", "Chris asked the team to update the launch pricing sheet."),
        ]
        try store.saveMeeting(meeting, chunks: chunks.enumerated().map { i, row in
            Store.ChunkInput(chunkID: row.0, meetingID: meeting.id, version: 0, seq: i,
                             speaker: row.1, tStart: Double(90 + i), tEnd: Double(100 + i),
                             text: row.2, contentHash: "b:\(row.0)")
        })
        for row in chunks {
            let v = try await embedder.embed([row.2], kind: .document)[0]
            try store.saveEmbedding(chunkID: row.0, space: space, dim: embedder.dim,
                                    modelID: embedder.modelID, vector: v, contentHash: "b:\(row.0)")
        }
        let ask = AskEngine(search: SearchEngine(store: store, embedder: embedder, space: space),
                            llm: ClaudeRunner(executablePath: "/nonexistent/claude", sandboxDir: sandbox()))

        // The query's OWN words reference the real transcript (BitRouter, Arena.dev, KYC, plate) —
        // retrieval must surface those moments from the query terms themselves, NOT from vocabulary
        // hardcoded into the engine (which used to be injected into every source-find query).
        let answer = try await ask.ask("Dom asked me to keep hounding the partner items like BitRouter and Arena.dev, and put the KYC referral work on my plate — find that call")

        #expect(answer.status == .answered)
        #expect(answer.provider == nil)
        #expect(answer.model == "local-source-find")
        #expect(answer.plan?.mode == .sourceFind)
        #expect(answer.citations.contains { $0.chunkID == "c_max_track" })
        #expect(answer.citations.contains { $0.chunkID == "c_max_plate" })
        #expect(!answer.citations.contains { $0.speaker == "Gemini Notes" || $0.speaker == "Chris" })
        #expect(answer.text.contains("2026-07-02 morning sync"))
        #expect(answer.text.contains("BitRouter"))
        #expect(answer.text.contains("Arena.dev"))
        #expect(answer.text.contains("plate"))
    }

    @Test("source-find for an unrelated topic is not polluted by another call's vocabulary")
    func sourceFindDoesNotPolluteUnrelatedTopic() async throws {
        let store = try freshStore()
        let embedder = StubEmbedder()
        let space = "stub__v1"
        let meeting = Meeting(id: "morning", title: "2026-07-02 morning sync", date: "2026-07-02", source: .gmeetLocal)
        let chunks: [(String, String, String)] = [
            ("c_max_track", "Dominic Vance", "Sam, keep someone hounding the partner items so BitRouter and Arena.dev do not fall off the map."),
            ("c_max_kyc", "Dominic Vance", "Work with Riley on the verification and KYC referral program, that is on your plate."),
            ("c_chris_pricing", "Chris", "We need to update the launch pricing sheet before the release."),
        ]
        try store.saveMeeting(meeting, chunks: chunks.enumerated().map { i, row in
            Store.ChunkInput(chunkID: row.0, meetingID: meeting.id, version: 0, seq: i,
                             speaker: row.1, tStart: Double(90 + i), tEnd: Double(100 + i),
                             text: row.2, contentHash: "b:\(row.0)")
        })
        for row in chunks {
            let v = try await embedder.embed([row.2], kind: .document)[0]
            try store.saveEmbedding(chunkID: row.0, space: space, dim: embedder.dim,
                                    modelID: embedder.modelID, vector: v, contentHash: "b:\(row.0)")
        }
        let ask = AskEngine(search: SearchEngine(store: store, embedder: embedder, space: space),
                            llm: ClaudeRunner(executablePath: "/nonexistent/claude", sandboxDir: sandbox()))

        // An unrelated source-find question. Before the overfit was removed, EVERY source-find query
        // was force-expanded with "BitRouter Arena.dev KYC referral partner…" and reranked toward those
        // words — so this pricing question could surface the BitRouter/KYC moments. The on-topic moment
        // must win.
        let answer = try await ask.ask("find where we said the launch pricing sheet needs updating")

        #expect(answer.plan?.mode == .sourceFind)
        #expect(answer.citations.first?.chunkID == "c_chris_pricing")
    }

    @Test("a named-speaker question with no lines from that speaker does not attribute others' words")
    func missingSpeakerDoesNotMisattribute() async throws {
        let store = try freshStore()
        let embedder = StubEmbedder()
        let space = "stub__v1"
        let meeting = Meeting(id: "m1", title: "Product sync", date: "2026-07-07", source: .fireflies)
        let chunks: [(String, String, String)] = [
            ("c_chris", "Chris", "The launch pricing sheet needs updating before release."),
            ("c_ghazal", "Priya", "We walked through the referral onboarding and the pricing tiers."),
        ]
        try store.saveMeeting(meeting, chunks: chunks.enumerated().map { i, row in
            Store.ChunkInput(chunkID: row.0, meetingID: meeting.id, version: 0, seq: i,
                             speaker: row.1, tStart: Double(10 + i), tEnd: Double(20 + i),
                             text: row.2, contentHash: "b:\(row.0)")
        })
        for row in chunks {
            let v = try await embedder.embed([row.2], kind: .document)[0]
            try store.saveEmbedding(chunkID: row.0, space: space, dim: embedder.dim,
                                    modelID: embedder.modelID, vector: v, contentHash: "b:\(row.0)")
        }
        let llm = AskEvidenceTests.PromptCapturingLLM()
        let ask = AskEngine(search: SearchEngine(store: store, embedder: embedder, space: space), llm: llm)

        // "Dom" never spoke; the old code silently answered from Chris/Priya as if it were Dom.
        _ = try await ask.ask("what did Dom say about the pricing?")
        let prompt = try #require(llm.lastPrompt)

        #expect(prompt.contains("No source line is labeled as Dom"))
    }

    @Test("source-find naming a speaker with no lines refuses instead of pointing at someone else")
    func sourceFindMissingSpeakerRefuses() async throws {
        let store = try freshStore()
        let embedder = StubEmbedder()
        let space = "stub__v1"
        let meeting = Meeting(id: "m1", title: "Product sync", date: "2026-07-07", source: .fireflies)
        let text = "The launch pricing sheet is wrong and needs updating."
        try store.saveMeeting(meeting, chunks: [
            Store.ChunkInput(chunkID: "c_chris", meetingID: meeting.id, version: 0, seq: 0,
                             speaker: "Chris", tStart: 10, tEnd: 20, text: text, contentHash: "b:c_chris")
        ])
        let v = try await embedder.embed([text], kind: .document)[0]
        try store.saveEmbedding(chunkID: "c_chris", space: space, dim: embedder.dim,
                                modelID: embedder.modelID, vector: v, contentHash: "b:c_chris")
        let ask = AskEngine(search: SearchEngine(store: store, embedder: embedder, space: space),
                            llm: ClaudeRunner(executablePath: "/nonexistent/claude", sandboxDir: sandbox()))

        // Dom never spoke; the pricing line is Chris's. Source-find must not present it as Dom's.
        let answer = try await ask.ask("Dom said the pricing was wrong, find that call")

        #expect(answer.plan?.mode == .sourceFind)
        #expect(answer.plan?.speaker == "Dom")
        #expect(answer.status == .noSources)
        #expect(answer.text.contains("Dom"))
        #expect(answer.citations.isEmpty)
    }

    @Test("ambiguous retrieval retries with expanded aliases when the first pass is weak")
    func ambiguousRetrievalExpandsAliases() async throws {
        let store = try freshStore()
        let embedder = StubEmbedder()
        let space = "stub__v1"
        let meeting = Meeting(id: "m1", title: "Product sync", date: "2026-07-07", source: .fireflies)
        let text = "Dom said the Slackbot should post follow-ups after each partner call."
        try store.saveMeeting(meeting, chunks: [
            Store.ChunkInput(chunkID: "c_slackbot", meetingID: meeting.id, version: 0, seq: 0,
                             speaker: "Dom", tStart: 10, tEnd: 20, text: text, contentHash: "b:slackbot")
        ])
        let v = try await embedder.embed([text], kind: .document)[0]
        try store.saveEmbedding(chunkID: "c_slackbot", space: space, dim: embedder.dim,
                                modelID: embedder.modelID, vector: v, contentHash: "b:slackbot")
        let llm = AskEvidenceTests.PromptCapturingLLM()
        let ask = AskEngine(search: SearchEngine(store: store, embedder: embedder, space: space), llm: llm)

        let answer = try await ask.ask("what did we decide about the slack bot?")
        let prompt = try #require(llm.lastPrompt)

        #expect(answer.status == .answered)
        #expect(prompt.contains("Slackbot should post follow-ups"))
    }

    @Test("empty retrieval expands and then refuses with searched terms")
    func emptyRetrievalReportsSearchedTerms() async throws {
        let store = try freshStore()
        let ask = AskEngine(
            search: SearchEngine(store: store, embedder: StubEmbedder(), space: "stub__v1"),
            llm: ClaudeRunner(executablePath: "/nonexistent/claude", sandboxDir: sandbox())
        )

        let answer = try await ask.ask("where did anyone discuss frobnitz arbitrage?")

        #expect(answer.status == .noSources)
        #expect(answer.text.contains("Searched:"))
        #expect(answer.provider == nil)
    }
}
