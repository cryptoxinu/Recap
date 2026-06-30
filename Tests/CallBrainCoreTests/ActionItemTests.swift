import Testing
import Foundation
@testable import CallBrainCore

@Suite("ActionItemExtractor + tasks store")
struct ActionItemTests {

    private func utterances(_ lines: [String]) -> [ParsedUtterance] {
        lines.enumerated().map { i, l in
            ParsedUtterance(seq: i, speakerRaw: "Gemini Notes", tStart: 0, tEnd: 0, text: l, tsConfidence: .none)
        }
    }

    @Test("[Owner] lines anywhere + bullets under an action section become tasks; others ignored")
    func extracts() {
        let items = ActionItemExtractor.fromNotes(utterances([
            "## Community and analytics",
            "Zade implemented Discord scrapers.",                 // not a task
            "[Zade Kal] Discord API: Use the official interface", // owner task anywhere
            "## Next steps",
            "Follow up with Travis on tokenomics",                // bullet in action section
            "• Send Ghazal the mock-up feedback",                 // bullet (• stripped)
            "## Revenue and billing",
            "Need a central cost endpoint.",                      // not a task (outside action section)
        ]))
        let texts = items.map(\.text)
        #expect(items.contains { $0.owner == "Zade Kal" && $0.text == "Discord API: Use the official interface" })
        #expect(texts.contains("Follow up with Travis on tokenomics"))
        #expect(texts.contains("Send Ghazal the mock-up feedback"))
        #expect(!texts.contains("Need a central cost endpoint."))
        #expect(!texts.contains("Zade implemented Discord scrapers."))
    }

    @Test("dedupes identical owner+text")
    func dedupes() {
        let items = ActionItemExtractor.fromNotes(utterances([
            "[Zade] ship it", "[Zade] ship it", "[zade] Ship It",
        ]))
        #expect(items.count == 1)
    }

    @Test("tasks persist with the meeting and survive re-ingest without duplicating or clobbering status")
    func tasksStore() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("cb-tasks-\(UUID().uuidString).sqlite").path
        let store = try Store(path: path)
        let engine = IngestEngine(store: store, embedder: StubEmbedder(), space: "stub__v1")

        let notes = """
        Daily sync
        ## Next steps
        [Zade] Wire the tasks view
        Follow up with Max on pricing
        """
        _ = try await engine.ingestGeminiNotes(notes, title: "Daily sync", date: "2026-06-29")
        var rows = try store.tasks()
        #expect(rows.count == 2)
        #expect(rows.contains { $0.item.owner == "Zade" && $0.item.text == "Wire the tasks view" })
        #expect(try store.openTaskCount() == 2)

        // user completes one
        let zadeTask = rows.first { $0.item.owner == "Zade" }!
        try store.setTaskStatus(id: zadeTask.item.id, .done)
        #expect(try store.openTaskCount() == 1)

        // re-ingest the same notes (different date → not deduped meeting) … but same-content re-import:
        _ = try await engine.ingestGeminiNotes(notes, title: "Daily sync", date: "2026-06-29")
        rows = try store.tasks()
        #expect(rows.count == 2)                       // no duplicate tasks
        #expect(try store.tasks(status: .done).count == 1)   // toggled status preserved
    }

    @Test("LIVE: the real morning-sync notes yield owner-attributed tasks",
          .enabled(if: FileManager.default.fileExists(atPath: DocxReaderTestsPath.realDocx)))
    func liveTasks() throws {
        let text = try DocxReader.read(url: URL(fileURLWithPath: DocxReaderTestsPath.realDocx))
        let parsed = try GeminiNotesParser.parse(text, title: "morning sync", date: "2026-06-29")
        let items = ActionItemExtractor.fromNotes(parsed.utterances)
        #expect(!items.isEmpty)
        print("TASKS (\(items.count)): " + items.prefix(8).map { "[\($0.owner ?? "—")] \($0.text)" }.joined(separator: " | "))
    }
}
