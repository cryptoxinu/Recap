import Foundation
import CallBrainCore

// Dev tool: populate a CallBrain store so the app's UI can be verified by screenshot. Usage:
//   cbseed <storePath> <file> [gemini <title> <date> | raw | file]
//   cbseed <storePath> demojobs                 # seed sample import-queue rows (UI QA)

@main
struct CBSeed {
    static func main() async {
        let a = CommandLine.arguments
        guard a.count >= 3 else {
            FileHandle.standardError.write(Data("usage: cbseed <storePath> <file> [gemini <title> <date> | raw | file]\n       cbseed <storePath> demojobs\n".utf8))
            exit(2)
        }
        let storePath = a[1], file = a[2]
        let mode = a.count > 3 ? a[3] : "raw"
        do {
            let store = try Store(path: storePath)

            if file == "demojobs" {
                try seedDemoJobs(store)
                print("seeded demo import jobs")
                return
            }

            let embedder = OllamaEmbedder()
            let ingest = IngestEngine(store: store, embedder: embedder, space: "nomic__v1")
            let sandbox = NSTemporaryDirectory() + "cbseed-sandbox"
            try? FileManager.default.createDirectory(atPath: sandbox, withIntermediateDirectories: true)
            let importer = AIImporter(llm: ClaudeRunner(sandboxDir: sandbox))

            let outcome: IngestEngine.Outcome
            switch mode {
            case "gemini":
                let text = try String(contentsOfFile: file, encoding: .utf8)
                outcome = try await ingest.ingestGeminiNotes(text, title: a.count > 4 ? a[4] : nil, date: a.count > 5 ? a[5] : nil)
            case "file":   // native path: .docx via DocxReader, filename title/date, detect→parse
                let resolved: AIImporter.Resolved
                (outcome, resolved) = try await ingest.ingestFile(at: URL(fileURLWithPath: file), importer: importer)
                let job = ImportJob(id: "j_seed_\(UUID().uuidString)",
                                    sourceName: URL(fileURLWithPath: file).lastPathComponent,
                                    state: resolved.usedAI ? .needsReview : .done,
                                    format: resolved.format.rawValue, usedAI: resolved.usedAI,
                                    meetingID: outcome.meetingID, title: resolved.transcript.title,
                                    chunkCount: outcome.chunkCount, createdAt: Date().timeIntervalSince1970)
                try store.upsertImportJob(job)
            default:
                let text = try String(contentsOfFile: file, encoding: .utf8)
                (outcome, _) = try await ingest.ingestRaw(text, importer: importer)
            }
            print("seeded \(outcome.meetingID): \(outcome.chunkCount) chunks, \(outcome.embedded) embedded")
        } catch {
            FileHandle.standardError.write(Data("seed error: \(error)\n".utf8))
            exit(1)
        }
    }

    static func seedDemoJobs(_ store: Store) throws {
        let now = Date().timeIntervalSince1970
        let jobs = [
            ImportJob(id: "j_demo1", sourceName: "morning sync … Notes by Gemini.docx", state: .done,
                      format: "geminiNotes", usedAI: false, meetingID: nil, title: "morning sync",
                      chunkCount: 7, createdAt: now),
            ImportJob(id: "j_demo2", sourceName: "pasted-standup.txt", state: .needsReview,
                      format: "unknown", usedAI: true, meetingID: nil, title: "Bittensor validator standup",
                      chunkCount: 12, message: "AI structured this — open it to confirm speakers/turns look right.",
                      createdAt: now - 30),
            ImportJob(id: "j_demo3", sourceName: "broken-export.docx", state: .failed,
                      format: nil, usedAI: false, title: nil, chunkCount: 0,
                      message: "That doesn't look like a readable .docx file.", createdAt: now - 60),
        ]
        for j in jobs { try store.upsertImportJob(j) }
    }
}
