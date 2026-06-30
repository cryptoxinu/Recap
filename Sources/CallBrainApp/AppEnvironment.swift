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
    /// Battery-aware serial lifecycle for the local summary model (one at a time, unloads when idle).
    private(set) var summaries: SummaryScheduler!
    /// Fathom auto-import (polls the Fathom API) — dormant until the founder pastes an API key.
    private(set) var fathom: FathomConnect!
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
        self.summaries = SummaryScheduler(env: self)    // battery-aware local-summary lifecycle
        self.fathom = FathomConnect(env: self)          // dormant unless the founder connected Fathom
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

    /// Bumps when a call's AI title/summary lands, so meeting lists can live-refresh.
    var titlesRevision = 0

    /// Generate (or refresh) the AI title + one-line summary for a call, then persist it. Async core.
    @discardableResult
    func runTitleIntelligence(for meetingID: String, force: Bool = false) async -> Bool {
        guard let m = try? store.meeting(id: meetingID) else { return false }
        if !force, m.aiTitle?.isEmpty == false { return false }
        let utts = (try? store.utterances(meetingID: meetingID)) ?? []
        let text = utts.map { ($0.speaker.map { "\($0): " } ?? "") + $0.text }.joined(separator: "\n")
        guard let r = await TitleIntelligence(llm: router).generate(from: text, fallbackTitle: m.title) else { return false }
        try? store.setMeetingIntelligence(id: meetingID, aiTitle: r.title, aiSummary: r.summary)
        titlesRevision &+= 1
        return true
    }

    /// Fire-and-forget single title (import path).
    func generateTitleIntelligence(for meetingID: String, force: Bool = false) {
        Task { [weak self] in await self?.runTitleIntelligence(for: meetingID, force: force) }
    }

    @ObservationIgnored private var titleBackfilling = false
    /// Fill in titles for calls that don't have one yet — SERIALLY (one CLI call at a time), never a
    /// stampede of concurrent jobs on launch.
    func backfillTitleIntelligence() {
        guard !titleBackfilling else { return }
        titleBackfilling = true
        Task { [weak self] in
            guard let self else { return }
            for m in self.recentMeetings() where (m.aiTitle?.isEmpty ?? true) {
                await self.runTitleIntelligence(for: m.id)
            }
            self.titleBackfilling = false
        }
    }

    /// The routine local model. Qwen2.5-3B via Ollama — ~3× faster + 4-8× cooler than 14B (so a background
    /// summary never spins the fans), while still the most JSON-reliable model in its class (research
    /// 2026-06-30). The heavyweight 14B / premium quality is the explicit "Regenerate with AI" (cloud Opus)
    /// pass only — never automatic. Configurable in Settings.
    var localSummaryModel: String {
        UserDefaults.standard.string(forKey: "callbrain.localSummaryModel") ?? "qwen2.5:3b"
    }

    /// Generate the Summary-tab content for a call.
    /// - Gemini-notes calls REUSE Google's notes (zero compute) unless `preferCloud` (the user's "Regenerate
    ///   with AI" button).
    /// - Otherwise summarize the transcript LOCALLY (Ollama Qwen) by default — free + private; falls back to
    ///   the CLI subscription if the local model is unavailable. `preferCloud` runs the premium CLI pass.
    @discardableResult
    func generateCallSummary(for meetingID: String, preferCloud: Bool = false) async -> Bool {
        guard let m = try? store.meeting(id: meetingID) else { return false }
        // Every call gets a concise Summary-tab digest — including Gemini calls (we summarize Google's notes
        // into a short digest; the full notes stay on the Transcript tab). Founder ask 2026-06-30: tabs on
        // every call.
        let utts = (try? store.utterances(meetingID: meetingID)) ?? []
        var text = utts.map { ($0.speaker.map { "\($0): " } ?? "") + $0.text }.joined(separator: "\n")
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Older rows store transcript_chunks but no utterances — fall back to those so they still summarize.
            let chunks = (try? store.transcript(meetingID: meetingID)) ?? []
            text = chunks.map { ($0.speaker.map { "\($0): " } ?? "") + $0.text }.joined(separator: "\n")
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }

        // Local-first chain: the small routine model → cloud as a last resort if Ollama is unavailable.
        // `preferCloud` (the "Regenerate with AI" button) goes straight to the premium CLI pass (Opus).
        let summarizers: [any Summarizer] = preferCloud
            ? [CLISummarizer(llm: router, model: "opus")]
            : [OllamaSummarizer(model: localSummaryModel),
               CLISummarizer(llm: router, model: "sonnet")]
        var result: CallSummary?
        for s in summarizers { if let r = await s.summarize(transcript: text, title: m.displayTitle) { result = r; break } }
        guard let r = result else { return false }
        try? store.setCallSummary(id: meetingID, summary: r.summary, source: r.source)
        // Refresh the call's to-dos idempotently (replaces prior OPEN summary tasks, keeps completed ones)
        // so a Regenerate doesn't accumulate reworded duplicates.
        let items = r.actionItems
            .map { ActionItemDraft(owner: $0.owner, text: String($0.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(280))) }
            .filter { !$0.text.isEmpty }
        try? store.setSummaryTasks(meetingID: meetingID, items: items)
        refreshReminders(); titlesRevision &+= 1
        return true
    }

    /// Whether an automatic local summary is still warranted (the call exists, isn't Gemini-notes, and has
    /// no summary yet). Re-checked just before an auto pass runs so a user "Regenerate" that already
    /// produced one isn't redundantly re-summarized by a stale queued job.
    func needsAutoSummary(_ meetingID: String) -> Bool {
        guard let m = try? store.meeting(id: meetingID) else { return false }
        return m.callSummary?.isEmpty ?? true
    }

    /// Queue an automatic local summary through the battery-aware scheduler (import path).
    func summarizeInBackground(_ meetingID: String) { summaries.enqueueAuto(meetingID) }

    /// On launch, queue summaries for any calls that don't have one yet — serialized + battery-gated.
    func backfillSummaries() { summaries.backfillMissing(recentMeetings()) }

    // MARK: - call categorization (Ambient / Further Health / Other)

    /// Heuristic-first, with a local-LLM tiebreaker only for genuinely ambiguous calls (free + private).
    private var categoryEngine: CategoryEngine { CategoryEngine() }
    @ObservationIgnored private var pendingCategory: [String] = []
    @ObservationIgnored private var categoryDraining = false

    /// Classify one call into its venture and persist it. Skips calls the user categorized by hand.
    @discardableResult
    func classifyCategory(for meetingID: String) async -> Bool {
        guard let m = try? store.meeting(id: meetingID), !m.categoryManual else { return false }
        let utts = (try? store.utterances(meetingID: meetingID)) ?? []
        let people = ((try? store.entities(meetingID: meetingID)) ?? [])
            .filter { $0.kind == .person }.map(\.name)
        let body = utts.prefix(80).map(\.text).joined(separator: " ")
        let signal = [m.displayTitle, m.title, m.aiSummary ?? "", m.callSummary ?? "",
                      people.joined(separator: " "), body].joined(separator: "\n")
        let r = await categoryEngine.categorize(text: signal)
        try? store.setAutoCategory(id: meetingID, category: r.category.rawValue, confidence: r.confidence)
        titlesRevision &+= 1
        return true
    }

    /// Queue classification on a SERIAL chain — confident heuristic calls return instantly, so the only
    /// thing that ever serializes is the rare LLM tiebreaker (never many local-model calls at once).
    func classifyInBackground(_ meetingID: String) {
        if !pendingCategory.contains(meetingID) { pendingCategory.append(meetingID) }
        guard !categoryDraining else { return }
        categoryDraining = true
        Task { [weak self] in
            while let self, !self.pendingCategory.isEmpty {
                await self.classifyCategory(for: self.pendingCategory.removeFirst())
            }
            self?.categoryDraining = false
        }
    }

    /// On launch, classify any calls that don't have a category yet (all of them, not just the recent window).
    func backfillCategories() {
        for id in (try? store.meetingsNeedingCategory()) ?? [] { classifyInBackground(id) }
    }

    /// User picked a category by hand — pinned (auto-classification won't overwrite it).
    func setCategoryManual(_ meetingID: String, _ category: CallCategory) {
        try? store.setCategory(id: meetingID, category: category.rawValue, confidence: 1.0, manual: true)
        titlesRevision &+= 1
    }

    struct ReconcileSummary: Sendable { let reworded: Int; let completed: Int; let deduped: Int; let added: Int }

    /// "Tidy with AI" — reconcile the whole task list against every call: reword for clarity, mark ones the
    /// calls show are done, merge duplicates, add missed tasks. Safe: completion/dedup mark Done
    /// (reversible), additions are FK-checked to a real call, nothing is hard-deleted.
    func reconcileTasks() async -> ReconcileSummary? {
        let openRows = (try? store.tasks(status: .open)) ?? []
        let ctx = openRows.map {
            TaskIntelligence.TaskContext(id: $0.item.id, owner: $0.item.owner, text: $0.item.text, meeting: $0.meetingTitle)
        }
        let meetings = recentMeetings()
        let validIDs = Set(meetings.map(\.id))
        var evidence = ""
        for m in meetings.prefix(20) {
            let utts = (try? store.utterances(meetingID: m.id)) ?? []
            let body = utts.map { ($0.speaker.map { "\($0): " } ?? "") + $0.text }.joined(separator: "\n")
            evidence += "## CALL meetingID=\(m.id) — \(m.displayTitle) (\(m.date))\n" + String(body.prefix(2500)) + "\n\n"
            if evidence.count > 14000 { break }
        }
        guard let plan = await TaskIntelligence(llm: router).reconcile(tasks: ctx, evidence: evidence) else { return nil }

        var rew = 0, comp = 0, dedup = 0, added = 0
        let openIDs = Set(openRows.map(\.item.id))
        // Sanitize LLM-produced strings before they hit the DB / UI (SME MED — guard empty/huge/multiline).
        func clean(_ s: String?, max: Int) -> String? {
            guard let s else { return nil }
            let t = s.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : String(t.prefix(max))
        }
        for u in plan.reword where openIDs.contains(u.id) {
            guard let text = clean(u.text, max: 280) else { continue }   // skip garbage rewrites
            try? store.updateTaskText(id: u.id, text: text, owner: clean(u.owner, max: 80)); rew += 1
        }
        for id in Set(plan.complete) where openIDs.contains(id) { try? store.setTaskStatus(id: id, .done); comp += 1 }
        for id in Set(plan.duplicates) where openIDs.contains(id) { try? store.setTaskStatus(id: id, .done); dedup += 1 }
        for n in plan.add where validIDs.contains(n.meetingID) {
            guard let text = clean(n.text, max: 280) else { continue }
            if (try? store.addReconciledTask(meetingID: n.meetingID, owner: clean(n.owner, max: 80), text: text)) == true { added += 1 }
        }
        refreshReminders()
        return ReconcileSummary(reworded: rew, completed: comp, deduped: dedup, added: added)
    }

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
