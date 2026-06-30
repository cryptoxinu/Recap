import Testing
import Foundation
@testable import CallBrainCore

/// Opt-in live demos on real call data. Generic (env-driven) so no private content lives in the suite:
///   CALLBRAIN_LIVE=1 CALLBRAIN_GEMINI_FILE=<path> swift test --filter DemoTests
@Suite("LIVE demo on real call data")
struct DemoTests {

    private func freshStore() throws -> Store {
        try Store(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("cb-demo-\(UUID().uuidString).sqlite").path)
    }
    private func sandbox() -> String {
        let p = FileManager.default.temporaryDirectory.appendingPathComponent("cb-demo-sandbox").path
        try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return p
    }

    @Test("ingest real Gemini Meet notes → answer real questions",
          .enabled(if: ProcessInfo.processInfo.environment["CALLBRAIN_LIVE"] == "1"
                    && ProcessInfo.processInfo.environment["CALLBRAIN_GEMINI_FILE"] != nil))
    func liveGeminiNotes() async throws {
        let path = ProcessInfo.processInfo.environment["CALLBRAIN_GEMINI_FILE"]!
        let text = try String(contentsOfFile: path, encoding: .utf8)

        let store = try freshStore()
        let embedder = OllamaEmbedder()
        let space = "nomic__v1"
        let ingest = IngestEngine(store: store, embedder: embedder, space: space)
        let outcome = try await ingest.ingestGeminiNotes(text, title: "morning sync", date: "2026-06-29")
        print("\n=== INGESTED 'morning sync': \(outcome.chunkCount) chunks, \(outcome.embedded) embedded ===")

        let ask = AskEngine(
            search: SearchEngine(store: store, embedder: embedder, space: space),
            llm: ClaudeRunner(sandboxDir: sandbox()))

        for q in [
            "What are Zade's action items from this meeting?",
            "What is the status of the BitRouter integration?",
            "What concern was raised about scaling for the mainnet launch?",
        ] {
            let a = try await ask.ask(q, topK: 6)
            print("\nQ: \(q)\nA [\(a.status.rawValue)]: \(a.text)\n— cites: \(a.citations.map(\.tag))")
        }
        #expect(outcome.chunkCount > 0)
    }
}
