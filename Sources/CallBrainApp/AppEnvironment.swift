import SwiftUI
import CallBrainCore
import CallBrainTranscribe

/// Wires the CallBrainCore engines to a real on-disk store + local providers, for the app to use.
/// SQLite + CLI sandbox live under ~/Library/Application Support/CallBrain/.
@MainActor
@Observable
final class AppEnvironment {
    let store: Store
    let embedder: OllamaEmbedder
    let llm: ClaudeRunner
    let codex: CodexRunner
    let router: ProviderRouter
    /// Which provider answers first (persisted). Mirrors the router's primary for the UI.
    var providerPrimary: ProviderID
    let space = "nomic__v1"
    let dataRoot: URL
    /// Non-nil when the primary database could not be opened (surfaced in the UI — never silent).
    let initError: String?
    /// App-wide durable import queue (created at the end of init, once the store exists).
    private(set) var importCoordinator: ImportCoordinator!

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
        let claude = ClaudeRunner(sandboxDir: sandbox.path)
        let codexRunner = CodexRunner(sandboxDir: sandbox.path)
        self.llm = claude
        self.codex = codexRunner
        let savedPrimary = ProviderID(rawValue: UserDefaults.standard.string(forKey: Self.providerKey) ?? "") ?? .claude
        self.providerPrimary = savedPrimary
        self.router = ProviderRouter(claude: claude, codex: codexRunner, primary: savedPrimary)
        self.importCoordinator = ImportCoordinator(env: self)
    }

    static let providerKey = "callbrain.providerPrimary"

    /// Flip the primary generation provider (Settings) — persisted + applied to the live router.
    func setProviderPrimary(_ p: ProviderID) {
        let v: ProviderID = (p == .codex) ? .codex : .claude
        providerPrimary = v
        UserDefaults.standard.set(v.rawValue, forKey: Self.providerKey)
        router.setPrimary(v)   // synchronous (lock-guarded) → visible to the very next Ask
    }

    var search: SearchEngine { SearchEngine(store: store, embedder: embedder, space: space) }
    var ask: AskEngine { AskEngine(search: search, llm: router) }
    var ingest: IngestEngine { IngestEngine(store: store, embedder: embedder, space: space) }
    var importer: AIImporter { AIImporter(llm: router) }
    /// On-device transcription (Phase 3): WhisperKit + FluidAudio behind the Core protocols. `base`
    /// balances speed/accuracy. The adapters are CACHED (created once) so the model loads a single time
    /// and is reused across recordings — their lock-guarded init makes shared reuse safe.
    private let _transcriber = WhisperKitTranscriber(model: "base")
    private let _diarizer = FluidAudioDiarizer()
    var transcription: TranscriptionPipeline {
        TranscriptionPipeline(transcriber: _transcriber, diarizer: _diarizer)
    }

    func meetingCount() -> Int { (try? store.meetingCount()) ?? 0 }
    func openTaskCount() -> Int { (try? store.openTaskCount()) ?? 0 }
    func recentMeetings() -> [Store.MeetingRow] { (try? store.recentMeetings()) ?? [] }

    /// Re-arm the daily reminder with the current open-task count — call whenever tasks change (completed,
    /// imported, or a meeting deleted) so a scheduled notification never fires a stale count (P6 gate MED).
    func refreshReminders() { NotificationManager.refresh(openTaskCount: openTaskCount()) }
}
