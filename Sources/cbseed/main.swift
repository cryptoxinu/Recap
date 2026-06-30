import Foundation
import CallBrainCore

// Dev tool: ingest a transcript file into a CallBrain store path, so the app can be populated with
// real data and its UI verified by screenshot. Usage:
//   cbseed <storePath> <file> [gemini <title> <date> | raw]

@main
struct CBSeed {
    static func main() async {
        let a = CommandLine.arguments
        guard a.count >= 3 else {
            FileHandle.standardError.write(Data("usage: cbseed <storePath> <file> [gemini <title> <date> | raw]\n".utf8))
            exit(2)
        }
        let storePath = a[1], file = a[2]
        let mode = a.count > 3 ? a[3] : "raw"
        do {
            let store = try Store(path: storePath)
            let embedder = OllamaEmbedder()
            let ingest = IngestEngine(store: store, embedder: embedder, space: "nomic__v1")
            let text = try String(contentsOfFile: file, encoding: .utf8)
            let outcome: IngestEngine.Outcome
            if mode == "gemini" {
                outcome = try await ingest.ingestGeminiNotes(text, title: a.count > 4 ? a[4] : nil, date: a.count > 5 ? a[5] : nil)
            } else {
                let sandbox = NSTemporaryDirectory() + "cbseed-sandbox"
                try? FileManager.default.createDirectory(atPath: sandbox, withIntermediateDirectories: true)
                let importer = AIImporter(llm: ClaudeRunner(sandboxDir: sandbox))
                (outcome, _) = try await ingest.ingestRaw(text, importer: importer)
            }
            print("seeded \(outcome.meetingID): \(outcome.chunkCount) chunks, \(outcome.embedded) embedded")
        } catch {
            FileHandle.standardError.write(Data("seed error: \(error)\n".utf8))
            exit(1)
        }
    }
}
