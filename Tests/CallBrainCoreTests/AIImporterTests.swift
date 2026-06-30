import Testing
import Foundation
@testable import CallBrainCore

@Suite("AIImporter (paste-anything)")
struct AIImporterTests {

    @Test("detects known formats by signal count; unknown → AI")
    func detect() {
        let firefliesCopy = """
        Zade Kal: 00:00
         Hi.
        Maxwell Lang: 00:04
         Hey there.
        Travis Good: 04:09
         Pricing talk.
        """
        let fathom = """
        Travis  0:12
        On Render pricing.
        Me  0:18
        Got it.
        Max  0:22
        Sounds good.
        """
        let json = #"{"sentences":[{"speaker_name":"Max","text":"hi","start_time":1}]}"#
        let prose = "We talked about pricing and Travis said to come under OpenRouter. No structure here."

        #expect(AIImporter.detect(firefliesCopy) == .firefliesCopy)
        #expect(AIImporter.detect(fathom) == .fathom)
        #expect(AIImporter.detect(json) == .firefliesJSON)
        #expect(AIImporter.detect(prose) == .unknown)
    }

    @Test("recognized format resolves deterministically (no AI, no LLM call)")
    func deterministicNoAI() async throws {
        let firefliesCopy = """
        Zade Kal: 00:00
         Max.
        Maxwell Lang: 00:04
         Hey, how's it going?
        Travis Good: 04:09
         We need to come under OpenRouter pricing.
        """
        // llm points at a missing binary: if AI were invoked this would throw.
        let importer = AIImporter(llm: ClaudeRunner(executablePath: "/nonexistent/claude", sandboxDir: "/tmp"))
        let r = try await importer.resolve(firefliesCopy, generateTitleIfMissing: false)
        #expect(r.usedAI == false)
        #expect(r.format == .firefliesCopy)
        #expect(r.transcript.utterances.count == 3)
    }

    // Opt-in live: a messy, structureless dump that only AI can resolve.
    //   CALLBRAIN_LIVE=1 swift test --filter AIImporter
    @Test("LIVE: AI resolves a messy raw dump into structured turns + a title",
          .enabled(if: ProcessInfo.processInfo.environment["CALLBRAIN_LIVE"] == "1"))
    func liveAIResolve() async throws {
        let messy = """
        ok so this was the call w/ max and travis earlier — max said we should price at 10% under openrouter,
        travis jumped in: "we just need to come under the open router pricing we're currently at". then we
        talked TEEs, max explained encrypted-in-use ram. i asked about cost basis, he said ~225 per gpu hour,
        8 gpus a machine.
        """
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent("cb-aiimport").path
        try? FileManager.default.createDirectory(atPath: sandbox, withIntermediateDirectories: true)
        let importer = AIImporter(llm: ClaudeRunner(sandboxDir: sandbox))
        let r = try await importer.resolve(messy)
        #expect(r.usedAI == true)
        #expect(r.format == .unknown)
        #expect(!r.transcript.utterances.isEmpty)
        #expect((r.transcript.title?.isEmpty ?? true) == false)   // it named the import
        print("\nAI-RESOLVED title: \(r.transcript.title ?? "")  speakers: \(r.transcript.speakers)  turns: \(r.transcript.utterances.count)")
    }
}
