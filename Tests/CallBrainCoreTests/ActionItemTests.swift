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
            "Alex implemented Discord scrapers.",                 // not a task
            "[Alex King] Discord API: Use the official interface", // owner task anywhere
            "## Next steps",
            "Follow up with Riley on tokenomics",                // bullet in action section
            "• Send Priya the mock-up feedback",                 // bullet (• stripped)
            "## Revenue and billing",
            "Need a central cost endpoint.",                      // not a task (outside action section)
        ]))
        let texts = items.map(\.text)
        #expect(items.contains { $0.owner == "Alex King" && $0.text == "Discord API: Use the official interface" })
        #expect(texts.contains("Follow up with Riley on tokenomics"))
        #expect(texts.contains("Send Priya the mock-up feedback"))
        #expect(!texts.contains("Need a central cost endpoint."))
        #expect(!texts.contains("Alex implemented Discord scrapers."))
    }

    @Test("bullet-prefixed [Owner] line still attributes; negative placeholders dropped (gate MED)")
    func bulletOwnerAndNegatives() {
        let items = ActionItemExtractor.fromNotes(utterances([
            "## Action items",
            "• [Priya] Send pricing notes",        // bullet + owner → must attribute to Priya
            "No action items were identified.",      // placeholder → not a task
            "- [Dom] Model the emissions",           // dash bullet + owner
        ]))
        #expect(items.contains { $0.owner == "Priya" && $0.text == "Send pricing notes" })
        #expect(items.contains { $0.owner == "Dom" && $0.text == "Model the emissions" })
        #expect(!items.contains { $0.text.lowercased().contains("no action items") })
        #expect(items.count == 2)
    }

    @Test("multi-person owner list is parsed as the owner, not left inside the text (founder bug 2026-07-09)")
    func multiOwnerList() {
        let items = ActionItemExtractor.fromNotes(utterances([
            "[Priya Anand, Marco Ruiz, Dom] Discuss May Payouts: address traffic attribution",
        ]))
        #expect(items.count == 1)
        #expect(items[0].owner == "Priya Anand, Marco Ruiz, Dom")
        #expect(items[0].text == "Discuss May Payouts: address traffic attribution")
        #expect(!items[0].text.hasPrefix("["))   // names no longer stuck in the text
    }

    @Test("a bracketed non-owner (URL / sentence) is still NOT treated as an owner")
    func rejectsNonOwnerBracket() {
        // A long bracket that isn't a name list must not become an owner.
        #expect(ActionItemExtractor.ownerLine("[see https://example.com/very/long/path/here/xx] do it") == nil)
        // A comma-list of real names IS accepted even past the old 40-char cap.
        let ok = ActionItemExtractor.ownerLine("[Priya Anand, Marco Ruiz, Dom] Discuss payouts")
        #expect(ok?.owner == "Priya Anand, Marco Ruiz, Dom")
    }

    @Test("re-saving a meeting id preserves toggled task status (gate HIGH — no cascade wipe)")
    func reSavePreservesTaskStatus() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("cb-resave-\(UUID().uuidString).sqlite").path
        let store = try Store(path: path)
        let m = Meeting(id: "fixed_id", title: "Daily", date: "2026-06-29", source: .gmeetGemini)
        let chunk = Store.ChunkInput(chunkID: "fixed_id_c0", meetingID: "fixed_id", version: 0, seq: 0,
                                     speaker: "Gemini Notes", tStart: 0, tEnd: 0, text: "[Alex] ship it", contentHash: "h")
        let task = Store.TaskInput(id: "t0", owner: "Alex", text: "ship it", dedupeKey: "alex|ship it")
        try store.saveMeeting(m, chunks: [chunk], tasks: [task])
        try store.setTaskStatus(id: "t0", .done)
        #expect(try store.openTaskCount() == 0)

        // re-save the SAME meeting id (e.g. reprocessed) — must NOT cascade-wipe the done task
        try store.saveMeeting(m, chunks: [chunk], tasks: [task])
        let rows = try store.tasks()
        #expect(rows.count == 1)
        #expect(rows.first?.item.status == .done)            // toggled status preserved
        #expect(try store.meetingCount() == 1)
    }

    @Test("setSummaryAndTasks writes summary AND action items atomically in one call (B1)")
    func atomicSummaryAndTasks() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("cb-sumtask-\(UUID().uuidString).sqlite").path
        let store = try Store(path: path)
        try store.saveMeeting(Meeting(id: "m1", title: "call", date: "2026-07-04", source: .fathom), chunks: [])
        try store.setSummaryAndTasks(meetingID: "m1", summary: "We shipped it.", source: "local",
                                     items: [ActionItemDraft(owner: "Alex", text: "email Junney"),
                                             ActionItemDraft(owner: "Riley", text: "fix billing")])
        #expect(try store.meeting(id: "m1")?.callSummary == "We shipped it.")
        #expect(try store.tasks(meetingID: "m1").count == 2)   // both landed with the summary
    }

    @Test("dedupes identical owner+text")
    func dedupes() {
        let items = ActionItemExtractor.fromNotes(utterances([
            "[Alex] ship it", "[Alex] ship it", "[alex] Ship It",
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
        [Alex] Wire the tasks view
        Follow up with Dom on pricing
        """
        _ = try await engine.ingestGeminiNotes(notes, title: "Daily sync", date: "2026-06-29")
        var rows = try store.tasks()
        #expect(rows.count == 2)
        #expect(rows.contains { $0.item.owner == "Alex" && $0.item.text == "Wire the tasks view" })
        #expect(try store.openTaskCount() == 2)

        // user completes one
        let alexTask = rows.first { $0.item.owner == "Alex" }!
        try store.setTaskStatus(id: alexTask.item.id, .done)
        #expect(try store.openTaskCount() == 1)

        // re-ingest the same notes (different date → not deduped meeting) … but same-content re-import:
        _ = try await engine.ingestGeminiNotes(notes, title: "Daily sync", date: "2026-06-29")
        rows = try store.tasks()
        #expect(rows.count == 2)                       // no duplicate tasks
        #expect(try store.tasks(status: .done).count == 1)   // toggled status preserved
    }

    @Test("noise-note gate drops bare dates/amounts but keeps real tasks")
    func noiseNoteGate() {
        // Junk that inflated the founder's list.
        #expect(ActionItemExtractor.isNoiseNote("Jul 10, 2026"))
        #expect(ActionItemExtractor.isNoiseNote("2026-07-10"))
        #expect(ActionItemExtractor.isNoiseNote("$5M"))
        #expect(ActionItemExtractor.isNoiseNote("Q3"))
        // Real tasks survive.
        #expect(!ActionItemExtractor.isNoiseNote("Update pricing information"))
        #expect(!ActionItemExtractor.isNoiseNote("Provide the launch FDV"))
        #expect(!ActionItemExtractor.isNoiseNote("Talk to Dom soon"))
        // End-to-end: a date bullet under an action section is dropped; the real one kept.
        let utts = [
            ParsedUtterance(seq: 0, speakerRaw: "notes", tStart: 0, tEnd: 0, text: "## Action items"),
            ParsedUtterance(seq: 1, speakerRaw: "notes", tStart: 0, tEnd: 0, text: "• Jul 10, 2026"),
            ParsedUtterance(seq: 2, speakerRaw: "notes", tStart: 0, tEnd: 0, text: "• Update the pricing page"),
        ]
        let items = ActionItemExtractor.fromNotes(utts)
        #expect(items.count == 1)
        #expect(items.first?.text == "Update the pricing page")
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
