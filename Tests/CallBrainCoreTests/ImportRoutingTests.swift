import Testing
import Foundation
@testable import CallBrainCore

@Suite("Import routing (detect → parse, filename meta, file ingest)")
struct ImportRoutingTests {

    private static let realDocx =
        "/Users/z/CallBrain/data/raw/google_meet_recordings/morning sync - 2026_06_29 09_29 PDT - Notes by Gemini (1).docx"

    // MARK: detection

    @Test("Gemini notes (## sections, no timestamps) detected as geminiNotes")
    func detectsGemini() {
        let notes = """
        morning sync
        Jun 29, 2026
        ## Community and analytics
        Zade implemented Discord scrapers.
        ## Revenue and billing
        Need a central cost endpoint.
        """
        #expect(AIImporter.detect(notes) == .geminiNotes)
    }

    @Test("a timestamped transcript is NOT misread as Gemini notes")
    func transcriptNotGemini() {
        // Fireflies copy: `Name: H:MM:SS` headers — must win over the gemini heuristic.
        let copy = """
        Travis Good: 0:00:04
        On Render the GPU spot pricing dropped sharply.
        Max Lang: 0:00:21
        Validators stake to secure the network.
        Zade Kal: 0:00:38
        I shipped the importer last night.
        """
        #expect(AIImporter.detect(copy) == .firefliesCopy)
    }

    @Test("prose with no headers and no timestamps stays unknown (→ AI resolve)")
    func proseUnknown() {
        #expect(AIImporter.detect("just some freeform notes about a call, nothing structured here") == .unknown)
    }

    @Test("a Fathom-style transcript with ## bold headers does NOT misroute to Gemini (audit M3)")
    func fathomDocxNotGemini() {
        // DocxReader prefixes bold short lines with `## `; a colon-less Fathom header `Travis 0:00`
        // becomes `## Travis 0:00`. Must still be seen as a transcript, not shredded as notes.
        let t = """
        ## Section one
        ## Travis 0:00
        On Render the GPU spot pricing dropped sharply this week.
        ## Max 0:21
        Validators stake to secure the network.
        ## Zade 0:38
        I shipped the importer last night and it works.
        """
        #expect(AIImporter.detect(t) != .geminiNotes)        // header-density guard catches it
    }

    @Test("a verbose Fathom transcript with long multi-line turns still classifies as Fathom (re-audit MED)")
    func verboseFathomStillDetected() {
        // 3 bare headers but each turn has several body lines → low header density. Must NOT fall to AI-resolve.
        let t = """
        Travis  0:00
        On Render the GPU spot pricing dropped sharply this week.
        That materially lowers our inference cost basis.
        We should lock in capacity before it rebounds.
        Max  0:30
        Validators stake to secure the network and earn emissions.
        The economics depend on how aggressive emissions are this epoch.
        I'll model a few scenarios and share them.
        Zade  1:05
        I shipped the importer last night and it indexes cleanly.
        Next I'll wire the date-gated search and the tasks view.
        """
        #expect(AIImporter.detect(t) == .fathom)
    }

    @Test("single-section notes with stray timecodes route to AI-resolve, not shredded as Fathom (M4)")
    func straySectionTimecodesUnknown() {
        let t = """
        ## Quick notes
        We talked about latency 0:45 being a problem.
        Cost came up around 1:30 in the call.
        Spend tracking by 2:00 was the ask.
        """
        // Not a real transcript (prose, low header density) → AI-resolve rather than fabricate turns.
        #expect(AIImporter.detect(t) == .unknown)
    }

    // MARK: filename metadata

    @Test("filenameMeta parses the real Gemini export name")
    func filenameMetaGemini() {
        let url = URL(fileURLWithPath: "/x/morning sync - 2026_06_29 09_29 PDT - Notes by Gemini (1).docx")
        let meta = IngestEngine.filenameMeta(url)
        #expect(meta.title == "morning sync")
        #expect(meta.date == "2026-06-29")
    }

    @Test("filenameMeta handles dash-date and bare names")
    func filenameMetaVariants() {
        #expect(IngestEngine.filenameMeta(URL(fileURLWithPath: "/x/Weekly Standup - 2026-05-14.txt")).title == "Weekly Standup")
        #expect(IngestEngine.filenameMeta(URL(fileURLWithPath: "/x/Weekly Standup - 2026-05-14.txt")).date == "2026-05-14")
        let bare = IngestEngine.filenameMeta(URL(fileURLWithPath: "/x/random-dump.txt"))
        #expect(bare.date == nil)
        #expect(bare.title == "random-dump")     // no " - " → whole stem
    }

    // MARK: end-to-end file ingest (deterministic: StubEmbedder + no-LLM path)

    @Test("LIVE: ingestFile(real .docx) → titled, dated Gemini meeting with notes",
          .enabled(if: FileManager.default.fileExists(atPath: ImportRoutingTests.realDocx)))
    func ingestRealDocx() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("cb-imp-\(UUID().uuidString).sqlite").path
        let store = try Store(path: path)
        let engine = IngestEngine(store: store, embedder: StubEmbedder(), space: "stub__v1")
        // titleHint from filename means the no-op title path is taken → LLM never invoked.
        let importer = AIImporter(llm: ClaudeRunner(executablePath: "/nonexistent/claude",
                                                    sandboxDir: FileManager.default.temporaryDirectory.path))

        let (outcome, resolved) = try await engine.ingestFile(
            at: URL(fileURLWithPath: Self.realDocx), importer: importer)

        #expect(resolved.format == .geminiNotes)
        #expect(resolved.usedAI == false)
        #expect(resolved.transcript.source == .gmeetGemini)
        #expect(outcome.chunkCount > 0)
        #expect(outcome.embedded == outcome.chunkCount)

        let meeting = try store.meeting(id: outcome.meetingID)
        #expect(meeting?.title == "morning sync")
        #expect(meeting?.date == "2026-06-29")

        let utts = try store.utterances(meetingID: outcome.meetingID)
        #expect(utts.count > 5)
        #expect(utts.allSatisfy { $0.speaker == "Gemini Notes" })
        #expect(utts.contains { $0.text.contains("BitRouter") })
    }
}
