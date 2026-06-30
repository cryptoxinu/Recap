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
    /// Non-nil when the primary database could not be opened (surfaced in the UI — never silent).
    let initError: String?

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CallBrain", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let sandbox = base.appendingPathComponent("cli-sandbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        self.dataRoot = base

        let path = base.appendingPathComponent("callbrain.sqlite3").path
        do {
            self.store = try Store(path: path)
            self.initError = nil
        } catch {
            // Don't silently swallow: fall back to a UNIQUE temp store so the app still launches, and
            // surface the failure so the user knows imports won't persist (Codex Phase-1 fix).
            let tmp = NSTemporaryDirectory() + "callbrain-fallback-\(UUID().uuidString).sqlite3"
            do {
                self.store = try Store(path: tmp)
            } catch {
                fatalError("CallBrain could not open any database (primary: \(path); fallback: \(tmp)): \(error)")
            }
            self.initError = "Couldn't open your CallBrain database (\(error.localizedDescription)). "
                + "Using a temporary store — imports won't be saved. Quit and relaunch, or check the data folder in Settings."
        }

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
