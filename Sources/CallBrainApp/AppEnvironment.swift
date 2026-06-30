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
    /// Optional "watch a folder and auto-import" (created after the coordinator).
    private(set) var autoImport: FolderAutoImport!
    /// Google Drive cloud sync (OAuth) — dormant until the founder configures + connects.
    private(set) var drive: GoogleDriveConnect!
    /// The global Ask-AI conversation, owned here (not by the view) so an in-flight answer keeps running in
    /// the background and survives navigating away and back (founder bug 2026-06-30).
    let askChat = ChatModel()
    /// Per-call AskFred chats, also env-owned so an in-flight in-meeting answer survives leaving and
    /// reopening the workspace (parity with the global chat). Not observed — views observe the returned
    /// model, not this cache.
    @ObservationIgnored private var meetingChats: [String: ChatModel] = [:]
    let dbPath: String

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CallBrain", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let sandbox = base.appendingPathComponent("cli-sandbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        self.dataRoot = base

        let path = base.appendingPathComponent("callbrain.sqlite3").path
        self.dbPath = path
        Self.applyPendingRestoreIfAny(dbPath: path)   // swap in a staged restore before opening (Phase 8)
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
        self.autoImport = FolderAutoImport(env: self)   // resumes watching a configured folder, if any
        self.drive = GoogleDriveConnect(env: self)      // dormant unless the founder connected Google Drive
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
    /// Ask uses the strongest Claude model — at flat CLI-subscription cost the best model is free, and the
    /// founder wants Fireflies-grade answers. (Codex ignores the model hint and uses its own default at high
    /// reasoning.) The router doubles as the web-researcher, so "research online" follows the same Claude⇄
    /// Codex selector + transparent fallback.
    var ask: AskEngine { AskEngine(search: search, llm: router, model: "opus", webResearcher: router) }
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

    /// Delete a call and everything derived from it (chunks/embeddings/utterances/entities/tasks +
    /// meeting-scoped chats, with citations to it scrubbed from other chats). Refreshes the reminder
    /// since open-task counts may change. Returns false on failure (surfaced in the UI).
    @discardableResult
    func deleteMeeting(_ id: String) -> Bool {
        do { try store.deleteMeeting(id: id); refreshReminders(); meetingChats[id] = nil; return true }
        catch { return false }
    }

    /// The (background-survivable) AskFred chat for a call, created on first open and reused thereafter.
    /// Capped so a long session that opens many calls can't pin an unbounded number of ChatModels — idle
    /// chats are evicted first, never one with an answer in flight (SME).
    func meetingChat(_ meetingID: String) -> ChatModel {
        if let c = meetingChats[meetingID] { return c }
        if meetingChats.count >= 24 {
            for (k, v) in meetingChats where !v.busy {
                meetingChats[k] = nil
                if meetingChats.count < 24 { break }
            }
        }
        let c = ChatModel(meetingID: meetingID)
        meetingChats[meetingID] = c
        return c
    }

    /// Re-arm the daily reminder with the current open-task count — call whenever tasks change (completed,
    /// imported, or a meeting deleted) so a scheduled notification never fires a stale count (P6 gate MED).
    func refreshReminders() { NotificationManager.refresh(openTaskCount: openTaskCount()) }

    // MARK: - backup / restore (Phase 8)

    func backup(to url: URL) throws { try store.backup(to: url) }

    /// Stage a `.cbk` to be swapped in on next launch (a live DB can't be replaced under itself).
    /// Returns false if the file isn't a valid CallBrain backup.
    func stageRestore(from url: URL) -> Bool {
        guard Store.isValidBackup(at: url) else { return false }
        let pending = dbPath + ".pending-restore"
        try? FileManager.default.removeItem(atPath: pending)
        do { try FileManager.default.copyItem(at: url, to: URL(fileURLWithPath: pending)); return true }
        catch { return false }
    }

    /// On launch: if a restore was staged, back up the current DB then swap the staged file into place.
    static func applyPendingRestoreIfAny(dbPath: String) {
        let fm = FileManager.default
        let pending = dbPath + ".pending-restore"
        guard fm.fileExists(atPath: pending) else { return }
        defer { try? fm.removeItem(atPath: pending) }
        guard Store.isValidBackup(at: URL(fileURLWithPath: pending)) else { return }   // invalid → discard
        // Keep the previous DB as a safety net, and clear WAL/SHM so the restored file is authoritative.
        try? fm.removeItem(atPath: dbPath + ".pre-restore")
        if fm.fileExists(atPath: dbPath) { try? fm.moveItem(atPath: dbPath, toPath: dbPath + ".pre-restore") }
        try? fm.removeItem(atPath: dbPath + "-wal")
        try? fm.removeItem(atPath: dbPath + "-shm")
        try? fm.moveItem(atPath: pending, toPath: dbPath)
    }
}
