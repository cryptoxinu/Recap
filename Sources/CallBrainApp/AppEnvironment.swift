import SwiftUI
import CallBrainCore

/// Wires the CallBrainCore engines to a real on-disk store + local providers, for the app to use.
/// SQLite + CLI sandbox live under ~/Library/Application Support/CallBrain/.
@MainActor
@Observable
final class AppEnvironment {
    let store: Store
    let embedder: OllamaEmbedder
    let llm: ClaudeRunner
    let space = "nomic__v1"
    let dataRoot: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CallBrain", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let sandbox = base.appendingPathComponent("cli-sandbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)

        self.dataRoot = base
        self.store = (try? Store(path: base.appendingPathComponent("callbrain.sqlite3").path))
            ?? (try! Store(path: NSTemporaryDirectory() + "callbrain-fallback.sqlite3"))
        self.embedder = OllamaEmbedder()
        self.llm = ClaudeRunner(sandboxDir: sandbox.path)
    }

    var search: SearchEngine { SearchEngine(store: store, embedder: embedder, space: space) }
    var ask: AskEngine { AskEngine(search: search, llm: llm) }
    var ingest: IngestEngine { IngestEngine(store: store, embedder: embedder, space: space) }
    var importer: AIImporter { AIImporter(llm: llm) }

    func meetingCount() -> Int { (try? store.meetingCount()) ?? 0 }
    func recentMeetings() -> [Store.MeetingRow] { (try? store.recentMeetings()) ?? [] }
}
