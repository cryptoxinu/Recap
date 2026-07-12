import SwiftUI
import os
import CryptoKit
import Security
import CallBrainCore
import CallBrainAppCore
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
    /// Call Corpus export (Part B) — writes one clean file per call to a folder that auto-syncs to the
    /// server Mac for the founder's assistant bot. Dormant (off by default) until enabled in Settings.
    private(set) var corpus: CorpusExportService!
    /// The global Ask-AI conversation, owned here (not by the view) so an in-flight answer keeps running in
    /// the background and survives navigating away and back (founder bug 2026-06-30).
    let askChat = ChatModel()
    /// The selected sidebar tab, owned here (not RootView's private @State) so any view can switch tabs —
    /// e.g. a call's "go full screen" jumps to the Ask tab. Seeded from CALLBRAIN_TAB for screenshot QA.
    var selectedTab: SidebarItem? = SidebarItem(rawValue: ProcessInfo.processInfo.environment["CALLBRAIN_TAB"] ?? "home") ?? .home
    /// Per-call AskFred chats, also env-owned so an in-flight in-meeting answer survives leaving and
    /// reopening the workspace (parity with the global chat). Not observed — views observe the returned
    /// model, not this cache.
    @ObservationIgnored private var meetingChats: [String: ChatModel] = [:]
    let dbPath: String
    /// Shared Google Meet caption session fed by the Chrome extension local bridge. Generous caps: since a
    /// recording harvests this buffer as its SAVED transcript (T2), the caps must hold a full long meeting
    /// (~10h of dense talk) before truncating — and if they ever do, the recording falls back to WhisperKit.
    let meetSession = MeetSession(maxTurns: 20_000, maxTotalBytes: 8 * 1_024 * 1_024)
    /// Bound local extension server port, surfaced later in Settings. `nil` means startup failed non-fatally.
    private(set) var localServerPort: UInt16?
    /// Persistent local extension server retained for app lifetime.
    @ObservationIgnored private var localServer: LocalServer?

    /// The live environment, so the AppDelegate's `callbrain://` URL handler can reach it (one-click
    /// extension pairing launches the app, which then opens its own pairing window).
    static weak var current: AppEnvironment?

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
                fatalError("Recap could not open any database (primary: \(path); fallback: \(tmp)): \(error)")
            }
            self.initError = "Couldn't open your Recap database (\(error.localizedDescription)). "
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
        drainPendingEmbeddings()   // Task 5.1b: settle any Ollama-down IOUs from a prior session
        startPendingEmbeddingRetryLoop()   // …and keep retrying while any IOUs remain (gate MED)
        requeueLocalSummariesForV2()       // one-time: regenerate pre-v2 local summaries (founder)
        rebaselineSummaryTasksV3()         // one-time: de-slop the exploded summary tasks (founder)
        // Summary backfill is IDEMPOTENT (skips calls that already have one) and battery-gated —
        // run it every launch so a killed session can never strand summary-less calls. The
        // meetings read runs OFF-main (integration-audit MED).
        Task { @MainActor [weak self] in
            guard let self else { return }
            let store = self.store
            let rows = await Task.detached { (try? store.recentMeetings()) ?? [] }.value
            self.summaries.backfillMissing(rows)
        }
        self.autoImport = FolderAutoImport(env: self)
        self.drive = GoogleDriveConnect(env: self)
        self.summaries = SummaryScheduler(env: self)
        self.fathom = FathomConnect(env: self)
        self.corpus = CorpusExportService(store: store,
                                          defaultFolder: base.appendingPathComponent("corpus", isDirectory: true))
        // Launch catch-up (idempotent, cheap-skips everything already current) so a killed session can
        // never strand un-exported calls. No-ops unless corpus export is enabled.
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.corpus.reconcileOnLaunch()   // (re)install the sync agent if enabled, then catch-up export
        }
        startLocalServer()
        AppEnvironment.current = self   // let the URL handler reach the live env for one-click pairing
        refreshReminders()   // seed the cached menu-bar counts off-main (never blocks launch)
    }

    /// Calendar hub (C2) — created lazily so EventKit never loads for users who skip the tab.
    @ObservationIgnored private var _calendarHub: CalendarHub?
    var calendarHub: CalendarHub {
        if let h = _calendarHub { return h }
        let h = CalendarHub(env: self)
        _calendarHub = h
        return h
    }

    /// App-wide live-recording controller (menu bar + sidebar can drive it; survives tab
    /// switches). Lazy so a non-recording session never touches AVAudioEngine.
    @ObservationIgnored private var _recording: RecordingModel?
    var recording: RecordingModel {
        if let r = _recording { return r }
        let r = RecordingModel(); _recording = r; return r
    }
    /// Drives the Record panel sheet — any surface (sidebar, menu bar, ⌘R) flips this.
    var recordSheetShown = false

    /// Opt-in auto-record of calendar meetings with a conference link (default off).
    @ObservationIgnored private var _autoRecorder: MeetingAutoRecorder?
    var autoRecorder: MeetingAutoRecorder {
        if let a = _autoRecorder { return a }
        let a = MeetingAutoRecorder(); _autoRecorder = a; return a
    }

    /// Open the Record panel pre-filled for a specific calendar event so the resulting meeting
    /// auto-links to it (record-from-calendar). Never clobbers an in-flight recording's title or
    /// link — if one is already running, this just reopens its panel.
    func startRecordFlow(presetTitle: String? = nil, eventID: String? = nil) {
        let rec = recording
        if rec.phase == .idle {
            if let presetTitle, rec.title.isEmpty { rec.title = presetTitle }
            rec.pendingEventID = eventID   // committed to linkedEventID only when Start succeeds
        }
        recordSheetShown = true
    }

    /// Resolve durable recording→meeting hand-offs: for each pending row whose WAV has now been
    /// ingested (its import job carries a meeting_id), attach the founder's live notes and link
    /// the calendar event, then drop the row. Idempotent + safe to call repeatedly (on startup,
    /// after every import completes, and right after a recording stops). Survives app relaunch.
    func reconcileRecordingLinks() async {
        let store = self.store
        let pending = await Task.detached { (try? store.pendingRecordingLinks()) ?? [] }.value
        guard !pending.isEmpty else { return }
        for p in pending {
            let resolved = await Task.detached { try? store.meetingIDForImportPayload(p.filePath) }.value
            guard let mid = resolved ?? nil else { continue }   // not ingested yet — a later pass catches it
            // Only drop the durable intent once EVERY write actually succeeded — else a transient DB
            // or calendar-write failure would permanently lose the founder's notes / event link
            // (P2b audit HIGH). Both writes are idempotent (note append de-dupes, link is an upsert),
            // so retrying the whole row on partial failure is safe.
            var allOK = true
            // Stamp the meeting's real start time first — a recording's WAV lands here with a NULL
            // start_time, and the calendar auto-linker's strongest signal is start-time proximity.
            if let began = p.startedAt {
                let ok = await Task.detached { (try? store.setMeetingStartTimeIfUnset(meetingID: mid, startedAt: began)) != nil }.value
                allOK = allOK && ok
            }
            if let notes = p.notes, !notes.isEmpty {
                let ok = await Task.detached { (try? store.appendMeetingNote(meetingID: mid, note: notes)) != nil }.value
                allOK = allOK && ok
            }
            if let eventID = p.eventID, !eventID.isEmpty {
                let linkOK = await calendarHub.linkRecordingAwait(eventID: eventID, meetingID: mid)
                allOK = allOK && linkOK
            }
            if allOK {
                await Task.detached { try? store.deletePendingRecordingLink(filePath: p.filePath) }.value
            }
        }
    }

    /// ONE background-work scheduler (Task 5.1b, enabler E4 v1) — embedding backfill today;
    /// Phase 8 moves speaker naming / digest / linker review onto it. Never a fifth bespoke queue.
    let jobs = JobScheduler(budget: 2)

    /// Drain the pending-embeddings IOU queue (chunks imported while Ollama was down). Safe to
    /// call anytime: no-ops when the queue is empty, ends quietly when the embedder is still
    /// unreachable (the durable queue retries on the next trigger — launch or import).
    @ObservationIgnored private var drainingEmbeddings = false
    @ObservationIgnored private var drainRequestedAgain = false
    func drainPendingEmbeddings() {
        // Single-flight (integration-audit HIGH): launch + retry-loop + post-import + Start-local-AI
        // could all spawn drains over the SAME pending rows, duplicating Ollama work and
        // occupying both scheduler slots. If a request arrives WHILE draining (e.g. a re-correction just
        // enqueued rows after the drain read an empty queue), remember it and re-drain on exit so the new
        // rows don't wait for the 5-min retry (audit LOW).
        guard !drainingEmbeddings else { drainRequestedAgain = true; return }
        drainingEmbeddings = true
        drainRequestedAgain = false
        let done: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            self.drainingEmbeddings = false
            if self.drainRequestedAgain { self.drainRequestedAgain = false; self.drainPendingEmbeddings() }
        }
        let store = self.store, embedder = self.embedder, space = self.space, jobs = self.jobs
        Task.detached(priority: .utility) {
            defer { Task { @MainActor in done() } }
            await jobs.run(label: "embedding-backfill", priority: .background) {
                while true {
                    let pending = try store.pendingEmbeddings(limit: 64)
                    guard !pending.isEmpty else { break }
                    let ids = pending.map(\.chunkID)
                    let chunks = try store.chunks(ids: ids)
                    guard !chunks.isEmpty else { try store.clearPendingEmbeddings(chunkIDs: ids); continue }
                    let meetingIDs = Array(Set(chunks.map(\.meetingID)))
                    let meetingsByID = Dictionary(uniqueKeysWithValues: try meetingIDs.compactMap { id in
                        try store.meeting(id: id).map { (id, $0) }
                    })
                    let embeddingTexts = chunks.map { ch in
                        let meeting = meetingsByID[ch.meetingID]
                        return IngestEngine.embeddingText(title: meeting?.title, date: meeting?.date,
                                                          speaker: ch.speaker, text: ch.text)
                    }
                    let vectors = try await embedder.embed(embeddingTexts, kind: .document)
                    guard vectors.count == chunks.count else { break }
                    for (i, ch) in chunks.enumerated() {
                        let meeting = meetingsByID[ch.meetingID]
                        try store.saveEmbedding(chunkID: ch.chunkID, space: space, dim: embedder.dim,
                                                modelID: embedder.modelID, vector: vectors[i],
                                                contentHash: IngestEngine.embeddingContentHash(
                                                    title: meeting?.title, date: meeting?.date,
                                                    speaker: ch.speaker, text: ch.text))
                    }
                    try store.clearPendingEmbeddings(chunkIDs: chunks.map(\.chunkID))
                }
            }
        }
    }

    /// Summaries v2 (founder 2026-07-02: "the summaries are all pretty bad"): clear the old
    /// local-model summaries ONCE so the normal backfill regenerates them through the new
    /// fact-extraction pipeline. Battery-gated, serial, local — no cloud spend.
    private func requeueLocalSummariesForV2() {
        let key = "callbrain.summaryV2Requeued"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        let store = self.store
        Task { @MainActor in
            // Flag ONLY on success — a failed clear must retry next launch, or the pre-v2
            // summaries would be stranded forever. A crash after clear-before-flag just
            // re-runs an idempotent no-op clear.
            let cleared: Int? = await Task.detached { try? store.clearLocalSummaries() }.value
            guard let cleared else { return }
            UserDefaults.standard.set(true, forKey: key)
            if cleared > 0 { backfillSummaries() }
        }
    }

    /// One-time tasks re-baseline (founder: 320 noisy summary tasks): drop OPEN summary-derived
    /// tasks and re-derive each summarized call's action items through the new quality gate
    /// (commitments-only sweep — the summaries themselves stay). Serial, background, local.
    private func bumpAfterRebaseline() {
        titlesRevision &+= 1
        refreshReminders()
    }

    private func rebaselineSummaryTasksV3() {
        let key = "callbrain.tasksV3Rebaseline"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        let bumpAfterRebaseline = self.bumpAfterRebaseline
        let store = self.store, jobs = self.jobs, model = self.localSummaryModel
        Task.detached(priority: .utility) {
            // One cheap reachability probe FIRST: if the local model server is down (the founder's "Local
            // AI off"), skip the whole per-meeting pass instead of firing a failed request for EVERY
            // meeting on EVERY launch — that hammering of a dead Ollama was the launch-time "bogs down".
            // The flag stays unset, so the full idempotent pass simply retries a future launch when Ollama
            // is up. (Costs one 2s probe when local AI is off, vs. hundreds of per-meeting failures.)
            guard await SystemStatus.ollamaModels() != nil else { return }
            await jobs.run(label: "tasks-rebaseline", priority: .background) {
                let profile = await MainActor.run { PersonalProfile.load() }
                let summarizer = OllamaSummarizer(model: model, profile: profile)
                // The one-time flag is earned only by a FULLY clean pass (gate HIGH): any read
                // failure, partial sweep, or failed write leaves the flag unset so the next
                // launch retries the WHOLE idempotent pass.
                var ok = true
                let meetings: [Store.MeetingRow]
                do { meetings = try store.recentMeetings() } catch { meetings = []; ok = false }
                for m in meetings where (m.callSummary?.isEmpty == false) && m.summarySource == "local" {
                    let utts: [Store.UtteranceRow]
                    do { utts = try store.utterances(meetingID: m.id) } catch { ok = false; continue }
                    let text = utts.map { ($0.speaker.map { "\($0): " } ?? "") + $0.text }.joined(separator: "\n")
                    guard !text.isEmpty else { continue }
                    guard let (raw, complete) = await summarizer.extractCommitmentsOnlyDetailed(
                        transcript: text, title: m.displayTitle), complete
                    else { ok = false; continue }   // Ollama down / partial — retry next launch
                    let gated = FactPrompt.gateCommitments(MeetingFacts(commitments: raw).sanitized().commitments)
                    let items = gated.map { c in
                        ActionItemDraft(owner: c.owner, text: c.due.map { "\(c.task) (\($0))" } ?? c.task)
                    }
                    do { try store.setSummaryTasks(meetingID: m.id, items: items) } catch { ok = false }
                }
                if ok {
                    UserDefaults.standard.set(true, forKey: key)
                    await bumpAfterRebaseline()
                }
            }
        }
    }

    /// Every 5 minutes, drain IF any IOUs remain (gate MED: launch-only draining meant an
    /// Ollama restart mid-session never settled the queue). The cheap COUNT gate means this
    /// costs nothing when the queue is empty; the drain itself no-ops if Ollama is still down.
    private func startPendingEmbeddingRetryLoop() {
        let store = self.store
        Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                guard let self else { return }
                let pending = (try? store.pendingEmbeddings(limit: 1)) ?? []
                if !pending.isEmpty { await self.drainPendingEmbeddings() }
            }
        }
    }

    /// E3 sweep (Task 7.1c): run a store write off-main, LOGGING failure instead of `try?`
    /// swallowing it — "the save silently didn't happen" is this app's worst debugging shape.
    @discardableResult
    nonisolated static func loggedWrite(_ label: String, _ work: @escaping @Sendable () throws -> Void) async -> Bool {
        await Task.detached {
            do { try work(); return true }
            catch {
                Logger(subsystem: "com.callbrain", category: "store")
                    .error("\(label, privacy: .public) failed: \(error.localizedDescription)")
                return false
            }
        }.value
    }

    nonisolated static func sha256Hex(_ s: String) -> String {
        "sha256:" + SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// "Explain this" plumbing (Task 4.5, founder: "what the heck did that mean?"): a transcript/
    /// notes line posts a request; the mounted MeetingWorkspaceView consumes it into its docked
    /// AskFred chat (streaming, persisted — the full chat pipeline for free).
    struct ExplainRequest: Equatable, Sendable {
        let id: UUID
        let text: String
        let meetingID: String
        init(text: String, meetingID: String) { self.id = UUID(); self.text = text; self.meetingID = meetingID }
    }
    var explainRequest: ExplainRequest?

    // MARK: - ⌘K palette + THE canonical open-meeting route (Tasks 7.1/7.3 — was 3 divergent sheets)
    var paletteShown = false
    /// MeetingsView's NavigationStack path, env-owned so ANY surface can push a call open.
    var meetingsPath: [String] = {
        let id = ProcessInfo.processInfo.environment["CALLBRAIN_OPEN_MEETING"] ?? ""
        return id.isEmpty ? [] : [id]
    }()
    /// A chunk the just-opened workspace should scroll to (palette "moment" hits).
    var pendingFocusChunkID: String?
    /// A Recents thread the Ask tab should load (palette "chat" hits).
    var pendingOpenChatID: String?
    /// ⌘L — bump to ask the mounted AskPanel to focus its composer (closes the deferred 3.x LOW).
    var composerFocusRequest = 0
    /// Pre-filled composer text ("Ask about <person>", Task 8.2) — consumed by AskPanel on mount/change.
    var pendingAskDraft: String?
    /// ⌘F — bump to focus the transcript Find field in the open meeting (gate MED, Task 7.2).
    var findRequest = 0
    /// meetingID → proposed speaker mappings awaiting the founder's ✓ (Task 8.1 — never silent).
    var speakerProposals: [String: [SpeakerNamer.Mapping]] = [:]
    static let speakerDismissedKey = "callbrain.speakerNaming.dismissed"

    // MARK: - auto-complete tasks from a later call's transcript (Tasks-overhaul Phase 4)

    /// An OPEN task a later call's transcript suggests is done, but not confidently enough to auto-complete
    /// — surfaced in the Tasks review banner (Phase 5) for a ✓/✗ or "Have AI review". HIGH-confidence
    /// completions are auto-marked done and never land here.
    struct TaskCompletionReview: Identifiable, Equatable, Sendable {
        let id: String          // taskID (one review per task)
        let taskText: String
        let evidence: String    // the transcript sentence that suggested completion
        let meetingID: String
        let meetingTitle: String
    }
    /// Ambiguous completion suggestions awaiting review (in-memory, like `speakerProposals`).
    var taskCompletionReviews: [TaskCompletionReview] = []

    /// Scan a just-ingested call's transcript for OPEN tasks (from EARLIER calls) it reports as done.
    /// Deterministic + off-main: HIGH-confidence → auto-mark done (stamped with this call as the source);
    /// AMBIGUOUS → the review banner (NEVER auto-marked — founder's hard rule). Works with Local AI off.
    func completeMatchingTasks(for meetingID: String) {
        let store = self.store, jobs = self.jobs
        Task.detached(priority: .utility) { [weak self] in
            _ = self
            await jobs.run(label: "task-completion-scan", priority: .background) { [weak self] in
                // Open tasks that PREDATE this call — never let a call complete its OWN just-created tasks.
                let openRows = ((try? store.tasks(status: .open)) ?? []).filter { $0.item.meetingID != meetingID }
                guard !openRows.isEmpty else { return }
                let utts = ((try? store.utterances(meetingID: meetingID)) ?? []).map(\.text)
                guard !utts.isEmpty else { return }
                let matches = TaskCompletionDetector.detect(
                    openTasks: openRows.map { (id: $0.item.id, text: $0.item.text) }, utterances: utts)
                guard !matches.isEmpty else { return }
                let byID = Dictionary(openRows.map { ($0.item.id, $0) }, uniquingKeysWith: { a, _ in a })
                let title = (try? store.meeting(id: meetingID))?.displayTitle ?? "a recent call"
                var auto = 0
                var reviews: [TaskCompletionReview] = []
                for m in matches {
                    guard let row = byID[m.taskID] else { continue }
                    if m.confidence == .high {
                        if (try? store.setTaskStatus(id: m.taskID, .done, completedByMeetingID: meetingID)) == true { auto += 1 }
                    } else {
                        reviews.append(TaskCompletionReview(id: m.taskID, taskText: row.item.text,
                                                            evidence: m.evidence, meetingID: meetingID, meetingTitle: title))
                    }
                }
                let addedReviews = reviews, autoCount = auto
                await MainActor.run { [weak self] in
                    if !addedReviews.isEmpty { self?.addTaskCompletionReviews(addedReviews) }
                    if autoCount > 0 { self?.titlesRevision &+= 1; self?.refreshReminders() }
                }
            }
        }
    }

    /// Merge new ambiguous suggestions (de-dup by taskID, cap the pending set).
    private func addTaskCompletionReviews(_ new: [TaskCompletionReview]) {
        var seen = Set(taskCompletionReviews.map(\.id))
        for r in new where seen.insert(r.id).inserted { taskCompletionReviews.append(r) }
        if taskCompletionReviews.count > 50 { taskCompletionReviews = Array(taskCompletionReviews.suffix(50)) }
    }

    /// Founder confirmed a review item → mark it done (stamped with the call that suggested it).
    func confirmTaskCompletion(_ id: String) {
        guard let r = taskCompletionReviews.first(where: { $0.id == id }) else { return }
        taskCompletionReviews.removeAll { $0.id == id }
        let store = self.store, mid = r.meetingID
        Task.detached { _ = try? store.setTaskStatus(id: id, .done, completedByMeetingID: mid) }
        titlesRevision &+= 1; refreshReminders()
    }
    /// Founder rejected a review item → just drop it (task stays open).
    func dismissTaskCompletion(_ id: String) { taskCompletionReviews.removeAll { $0.id == id } }
    func dismissAllTaskCompletions() { taskCompletionReviews.removeAll() }

    /// "Have AI review" — hand ONLY the ambiguous review candidates + their evidence to the LLM (local
    /// Ollama in local-only mode, else the cloud router) so it clears the truly-done ones and drops the
    /// rest. Reuses `TaskIntelligence.reconcile`'s `complete` array, scoped to the pending set. Returns how
    /// many it confirmed done.
    @discardableResult
    func reviewTaskCompletionsWithAI() async -> Int {
        let reviews = taskCompletionReviews
        guard !reviews.isEmpty else { return 0 }
        let tasks = reviews.map { TaskIntelligence.TaskContext(id: $0.id, owner: nil, text: $0.taskText, meeting: $0.meetingTitle) }
        let evidence = reviews.map { "Task: \($0.taskText)\nHeard in \($0.meetingTitle): \"\($0.evidence)\"" }
            .joined(separator: "\n\n")
        let localOnly = UserDefaults.standard.bool(forKey: Self.localOnlyKey)
        let ti = localOnly
            ? TaskIntelligence(llm: OllamaLiveProvider(model: localSummaryModel), model: localSummaryModel)
            : TaskIntelligence(llm: router)
        guard let plan = await ti.reconcile(tasks: tasks, resolved: [], evidence: evidence) else { return 0 }
        let completeIDs = Set(plan.complete)
        let store = self.store
        let toComplete = reviews.filter { completeIDs.contains($0.id) }
        let confirmed = await Task.detached { () -> Int in
            var n = 0
            for r in toComplete where (try? store.setTaskStatus(id: r.id, .done, completedByMeetingID: r.meetingID)) == true { n += 1 }
            return n
        }.value
        // Remove ONLY the ids we reviewed — a new ambiguous suggestion added by a concurrent ingest during
        // the AI await must not be dropped unreviewed (self-audit race).
        let reviewedIDs = Set(reviews.map(\.id))
        taskCompletionReviews.removeAll { reviewedIDs.contains($0.id) }
        titlesRevision &+= 1; refreshReminders()
        return confirmed
    }

    /// Dismissed = persisted no (never re-propose, never re-spend the LLM call on reopen).
    func dismissSpeakerProposal(for meetingID: String) {
        speakerProposals[meetingID] = nil
        var d = Set(UserDefaults.standard.stringArray(forKey: Self.speakerDismissedKey) ?? [])
        d.insert(meetingID)
        UserDefaults.standard.set(Array(d), forKey: Self.speakerDismissedKey)
    }

    /// Task 8.1 — propose names for a diarized meeting's "Speaker N" labels (background,
    /// confidence-gated, review-only). Uses the fast sonnet lane; skips when already proposed.
    static let speakerAttemptedKey = "callbrain.speakerNaming.attempted"

    func suggestSpeakerNames(for meetingID: String) {
        // Local-only mode (F1): speaker-naming sends transcript samples + attendee names to the cloud —
        // skip it entirely so nothing leaves the Mac.
        guard !isLocalOnly else { return }
        // Attempted-marker (gate MED): ANY completed attempt — low-confidence, no candidates,
        // malformed reply — is terminal; reopening the call must not re-spend LLM calls.
        let attempted = Set(UserDefaults.standard.stringArray(forKey: Self.speakerAttemptedKey) ?? [])
        guard speakerProposals[meetingID] == nil,
              !attempted.contains(meetingID),
              !(UserDefaults.standard.stringArray(forKey: Self.speakerDismissedKey) ?? []).contains(meetingID)
        else { return }
        let store = self.store, router = self.router, jobs = self.jobs
        Task.detached(priority: .utility) { [weak self] in
            _ = self
            await jobs.run(label: "speaker-naming", priority: .background) { [weak self] in
                let utts = (try? store.utterances(meetingID: meetingID)) ?? []
                let labels = Array(Set(utts.compactMap(\.speaker))).sorted()
                guard SpeakerNamer.needsNaming(speakers: labels) else { return }
                var samples: [String: [String]] = [:]
                for u in utts {
                    guard let sp = u.speaker, samples[sp, default: []].count < 5, u.text.count > 20 else { continue }
                    samples[sp, default: []].append(u.text)
                }
                let candidates = (try? store.meetingPeople(ids: [meetingID], perMeeting: 12))?[meetingID] ?? []
                guard !candidates.isEmpty else { return }
                let prompt = SpeakerNamer.prompt(samples: samples, candidates: candidates)
                guard let completion = try? await router.complete(
                    prompt: prompt, system: "You match diarized speakers to attendee names. JSON only.",
                    model: "sonnet", timeout: 60) else { return }
                let mappings = SpeakerNamer.parse(completion.text,
                                                  validSpeakers: Set(labels),
                                                  validNames: Set(candidates))
                await MainActor.run { [weak self] in
                    var a = Set(UserDefaults.standard.stringArray(forKey: Self.speakerAttemptedKey) ?? [])
                    a.insert(meetingID)   // terminal — never re-spend on this call (gate MED)
                    UserDefaults.standard.set(Array(a), forKey: Self.speakerAttemptedKey)
                    if !mappings.isEmpty { self?.speakerProposals[meetingID] = mappings }
                }
            }
        }
    }

    /// The founder confirmed — apply and clear (Task 8.1). ASYNC so the caller can reload the
    /// transcript AFTER the rename lands (gate MED: the old fire-and-forget raced the reload).
    func applySpeakerNames(for meetingID: String) async {
        guard let mappings = speakerProposals[meetingID] else { return }
        speakerProposals[meetingID] = nil
        let store = self.store
        await Task.detached {
            for m in mappings { _ = try? store.renameSpeaker(meetingID: meetingID, from: m.speaker, to: m.name) }
        }.value
        titlesRevision &+= 1
    }

    /// The ONE way to open a call from anywhere: switch to Meetings, push the workspace.
    func openMeeting(_ id: String, focusChunkID: String? = nil) {
        pendingFocusChunkID = focusChunkID
        selectedTab = .meetings
        meetingsPath = [id]
    }

    static let providerKey = "callbrain.providerPrimary"
    static let extensionPairingTokenKey = "callbrain.extensionPairingToken"
    private static let extensionPairingTokenService = "com.callbrain.extension"
    private static let extensionPairingTokenAccount = "pairing-token"
    private static let extensionPairingTokenFallback = ProcessTokenCache()

    /// Shared bearer token used by the Chrome extension to authenticate to the loopback server.
    ///
    /// Generated once as 32 random bytes and persisted in the Keychain because the extension needs a
    /// stable pairing value across app relaunches. The future Settings UI can display/regenerate it
    /// from this property.
    var extensionPairingToken: String {
        Self.loadExtensionPairingToken()
    }

    /// Flip the primary generation provider (Settings) — persisted + applied to the live router.
    func setProviderPrimary(_ p: ProviderID) {
        let v: ProviderID = (p == .codex) ? .codex : .claude
        providerPrimary = v
        UserDefaults.standard.set(v.rawValue, forKey: Self.providerKey)
        router.setPrimary(v)   // synchronous (lock-guarded) → visible to the very next Ask
    }

    private func startLocalServer() {
        let server = LocalServer(token: extensionPairingToken, ask: ask, session: meetSession,
                                 onImport: { [weak self] text in
                                     guard let self else { return false }
                                     return await self.enqueueExtensionTranscript(text)
                                 },
                                 onMeetMuted: { [weak self] muted in
                                     await MainActor.run { self?.recording.setMeetMuted(muted) }
                                 },
                                 onRecordStart: { [weak self] in await self?.extensionStartRecording() ?? false },
                                 onRecordStop: { [weak self] in await self?.extensionStopRecording() },
                                 recordStatus: { [weak self] in
                                     await self?.extensionRecordStatus()
                                        ?? RecordStatusSnapshot(recording: false, processing: false, elapsed: "0:00")
                                 },
                                 onPaired: { [weak self] in await self?.extensionDidPair() })
        localServer = server

        Task { [weak self, server] in
            do {
                let port = try await server.start()
                await MainActor.run {
                    self?.localServerPort = port
                    self?.openPairingWindowIfUnpaired()   // ready to pair the moment the app is up
                    self?.installNativeMessagingHost(port: port)   // hardened pairing channel (Phase 4)
                }
            } catch {
                await MainActor.run {
                    self?.localServerPort = nil
                }
                Logger(subsystem: "com.callbrain", category: "local-server")
                    .error("local extension server failed to start: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func enqueueExtensionTranscript(_ text: String) async -> Bool {
        await importCoordinator.enqueuePaste(text)
    }

    /// Serializes bridge writes across server (re)binds: only the LATEST call may write, so an older
    /// detached writer can't land its stale port after a newer bind already wrote the current one
    /// (audit HIGH — unordered detached tasks).
    @ObservationIgnored private var nativeMessagingGeneration = 0

    /// Phase 4 — install/refresh the Chrome Native Messaging pairing channel. Writes the 0600 bridge
    /// file (live token + port) the `cbpairhost` binary reads, and (best-effort) the host manifest into
    /// each installed Chromium browser so it may launch that binary for our pinned extension. Runs off
    /// the main thread (filesystem writes); purely additive — the deep-link `/pair` path still works if
    /// this or the browser-side setup isn't in place. No-op-safe to call on every (re)bind.
    private func installNativeMessagingHost(port: UInt16) {
        nativeMessagingGeneration &+= 1
        let gen = nativeMessagingGeneration
        let token = extensionPairingToken
        // The host binary sits beside the app executable inside the bundle (copied by install-local.sh).
        let hostPath = Bundle.main.executableURL?.deletingLastPathComponent()
            .appendingPathComponent("cbpairhost").path
        // Only trust the install location if it's NOT user-writable: a manifest hard-codes an absolute
        // path to cbpairhost, so if the app ran from ~/Downloads and were later deleted/replaced, an
        // attacker could plant a binary at that stale path and Chrome would launch it for our pinned
        // extension (SME HIGH). /Applications requires admin to write, which closes that door.
        let inApplications = Bundle.main.bundlePath.hasPrefix("/Applications/")
        Task.detached(priority: .utility) { [weak self] in
            // A newer bind superseded this one before we started writing → skip, its writer owns the file.
            guard await MainActor.run(body: { self?.nativeMessagingGeneration == gen }) else { return }
            let appSupport = NativeMessagingInstaller.defaultApplicationSupport()
            let hostOK = hostPath.map { FileManager.default.isExecutableFile(atPath: $0) } ?? false
            let browsers = NativeMessagingInstaller.targetDirectories(applicationSupport: appSupport)
            // Advertise native messaging ONLY from a trusted /Applications install, with the host binary
            // present, and only when a Chromium browser is actually installed. Otherwise tear down any
            // manifest/bridge a prior real launch left — never leave a dangling manifest (SME MED) or a
            // plaintext token on disk for a user who'll never pair over native messaging (SME MED).
            guard inApplications, hostOK, let hostPath, !browsers.isEmpty else {
                NativeMessagingInstaller.removeHostManifest(applicationSupport: appSupport)
                NativeMessagingInstaller.removeBridge(applicationSupport: appSupport)
                return
            }
            do { _ = try NativeMessagingInstaller.writeBridge(token: token, port: port, applicationSupport: appSupport) }
            catch {
                Logger(subsystem: "com.callbrain", category: "pairing")
                    .error("native-messaging bridge write failed: \(error.localizedDescription, privacy: .public)")
            }
            let written = NativeMessagingInstaller.installHostManifest(hostPath: hostPath, applicationSupport: appSupport)
            Logger(subsystem: "com.callbrain", category: "pairing")
                .info("native-messaging host installed for \(written.count, privacy: .public) browser(s)")
        }
    }

    // MARK: - extension record control + auto-pair

    /// Extension auto-pairing state, surfaced in Settings. `.waiting` = a pairing window is open.
    enum PairingState: Equatable { case idle, waiting, paired }
    var pairingState: PairingState = .idle

    /// Open a 2-minute auto-pair window (Settings → "Pair extension"): while open, the extension can fetch
    /// the token from the loopback `/pair` endpoint (chrome-extension origin only) instead of copy-paste.
    @ObservationIgnored private var pairingGeneration = 0
    func startExtensionPairing() {
        localServer?.openPairingWindow(seconds: 120)
        pairingState = .waiting
        pairingGeneration &+= 1
        let gen = pairingGeneration
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(120))
            // Audit #10: a re-opened pairing window supersedes this timer — only the CURRENT generation
            // may flip back to idle, so an older timer can't cancel a freshly-opened window.
            guard let self, self.pairingGeneration == gen else { return }
            if self.pairingState == .waiting { self.pairingState = .idle }
        }
    }

    /// One-click pairing entry from the `callbrain://pair` deep link (the extension opens it, which
    /// launches/focuses this app). Brings the app forward so the user sees the pairing state, then opens
    /// the loopback pairing window the extension polls — no manual "Pair extension" click needed.
    func handlePairDeepLink() {
        NSApp.activate(ignoringOtherApps: true)
        // Cold launch: the server object exists (created synchronously in init) even before it finishes
        // binding, and openPairingWindow just records a deadline — so this is safe to call immediately.
        startExtensionPairing()
    }

    func extensionDidPair() { pairingState = .paired }

    /// Make pairing RELIABLE: whenever the app is running/focused and the extension hasn't paired THIS
    /// session, keep a pairing window open so the extension's poll to `/pair` just succeeds — no dependence
    /// on the deep-link tab firing perfectly. Called on launch and every time the app becomes active.
    /// Gated on the in-memory session state (not a persistent flag) so a re-loaded extension can always
    /// re-pair on the next launch; the window is origin-pinned to the real extension and grants only the
    /// non-sensitive loopback meeting API (a paired extension never calls `/pair`, so it just expires).
    func openPairingWindowIfUnpaired() {
        guard pairingState != .paired else { return }
        localServer?.openPairingWindow(seconds: 300)
    }

    /// Start a recording triggered from the extension's record button. Returns whether it's now recording
    /// (already-recording counts as success; a mic/screen-permission failure returns false so the extension
    /// can surface it). Opens the Record panel too so the founder sees the live session in the app.
    @discardableResult
    func extensionStartRecording() async -> Bool {
        if recording.phase == .recording { return true }
        guard recording.phase == .idle else { return false }   // mid-processing a prior stop
        recordSheetShown = true
        await recording.start(env: self)
        return recording.phase == .recording
    }

    func extensionStopRecording() async {
        guard recording.phase == .recording else { return }
        await recording.stop(env: self)
    }

    func extensionRecordStatus() -> RecordStatusSnapshot {
        RecordStatusSnapshot(recording: recording.phase == .recording,
                             processing: recording.phase == .processing,
                             elapsed: recording.elapsedString)
    }

    private static func makeExtensionPairingToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            Logger(subsystem: "com.callbrain", category: "local-server")
                .fault("SecRandomCopyBytes failed for extension pairing token: \(status, privacy: .public)")
            bytes = (0..<32).map { _ in UInt8.random(in: UInt8.min...UInt8.max) }
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func loadExtensionPairingToken() -> String {
        if let migrated = migrateLegacyExtensionPairingTokenIfNeeded() {
            return migrated
        }

        switch readExtensionPairingTokenFromKeychain() {
        case .found(let token):
            return token
        case .missing:
            let token = makeExtensionPairingToken()
            switch addExtensionPairingTokenToKeychain(token) {
            case .saved:
                return token
            case .duplicate:
                if case .found(let existing) = readExtensionPairingTokenFromKeychain() {
                    return existing
                }
                logExtensionPairingTokenFault("Keychain item already existed but could not be read")
                return processLifetimeExtensionPairingToken()
            case .failed(let status):
                logExtensionPairingTokenFault("Keychain add failed", status: status)
                return processLifetimeExtensionPairingToken()
            }
        case .failed(let status):
            logExtensionPairingTokenFault("Keychain read failed", status: status)
            return processLifetimeExtensionPairingToken()
        }
    }

    private static func migrateLegacyExtensionPairingTokenIfNeeded() -> String? {
        guard let legacy = UserDefaults.standard.string(forKey: extensionPairingTokenKey),
              !legacy.isEmpty else { return nil }

        switch addExtensionPairingTokenToKeychain(legacy) {
        case .saved:
            UserDefaults.standard.removeObject(forKey: extensionPairingTokenKey)
            return legacy
        case .duplicate:
            if case .found(let existing) = readExtensionPairingTokenFromKeychain() {
                UserDefaults.standard.removeObject(forKey: extensionPairingTokenKey)
                return existing
            }
            logExtensionPairingTokenFault("Legacy token migration found an unreadable Keychain item")
            return nil
        case .failed(let status):
            logExtensionPairingTokenFault("Legacy token migration failed", status: status)
            return nil
        }
    }

    private static func readExtensionPairingTokenFromKeychain() -> ExtensionPairingTokenReadResult {
        var query = extensionPairingTokenBaseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        switch status {
        case errSecSuccess:
            guard let data = out as? Data,
                  let token = String(data: data, encoding: .utf8),
                  !token.isEmpty else { return .failed(errSecDecode) }
            return .found(token)
        case errSecItemNotFound:
            return .missing
        default:
            return .failed(status)
        }
    }

    private static func addExtensionPairingTokenToKeychain(_ token: String) -> ExtensionPairingTokenSaveResult {
        var item = extensionPairingTokenBaseQuery()
        item[kSecValueData as String] = Data(token.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(item as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return .saved
        case errSecDuplicateItem:
            return .duplicate
        default:
            return .failed(status)
        }
    }

    private static func extensionPairingTokenBaseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: extensionPairingTokenService,
            kSecAttrAccount as String: extensionPairingTokenAccount,
        ]
    }

    private static func processLifetimeExtensionPairingToken() -> String {
        extensionPairingTokenFallback.token(make: makeExtensionPairingToken)
    }

    private static func logExtensionPairingTokenFault(_ message: String, status: OSStatus? = nil) {
        let logger = Logger(subsystem: "com.callbrain", category: "local-server")
        if let status {
            logger.fault("\(message, privacy: .public): \(status, privacy: .public)")
        } else {
            logger.fault("\(message, privacy: .public)")
        }
    }

    var search: SearchEngine { SearchEngine(store: store, embedder: embedder, space: space) }
    /// Ask uses the strongest Claude model — at flat CLI-subscription cost the best model is free, and the
    /// founder wants Fireflies-grade answers. (Codex ignores the model hint and uses its own default at high
    /// reasoning.) The router doubles as the web-researcher, so "research online" follows the same Claude⇄
    /// Codex selector + transparent fallback.
    static let deepAnswersKey = "callbrain.deepAnswers"
    static let localOnlyKey = "callbrain.localOnly"
    /// Local-only mode (Settings "Answers"): the user's "nothing leaves this Mac" switch. When ON, every
    /// automatic CLOUD pass — summary fallback, AI title, speaker-naming, task tidy — and the corpus sync
    /// are skipped, enforcing the promise app-wide instead of only on the Ask path (audit F1 HIGH).
    var isLocalOnly: Bool { UserDefaults.standard.bool(forKey: Self.localOnlyKey) }
    var ask: AskEngine {
        let pref = AskEngine.DeepAnswerPreference(
            rawValue: UserDefaults.standard.string(forKey: Self.deepAnswersKey) ?? "auto") ?? .auto
        let rewriter = QueryRewriter()
        let localOnly = UserDefaults.standard.bool(forKey: Self.localOnlyKey)
        return AskEngine(search: search, llm: router, model: "opus",
                         fastLLM: OllamaLiveProvider(model: localSummaryModel),   // instant in-call lane
                         webResearcher: localOnly ? nil : router,   // 9.4: no web egress either
                         identityAliases: FounderIdentity.aliases, profile: PersonalProfile.load(),
                         deepAnswers: pref,
                         queryRewriter: { q, h in await rewriter.rewrite(q, history: h) },
                         localOnly: localOnly)
    }
    var ingest: IngestEngine { IngestEngine(store: store, embedder: embedder, space: space) }
    var importer: AIImporter { AIImporter(llm: router, allowCloud: !isLocalOnly) }
    /// On-device transcription (Phase 3): WhisperKit + FluidAudio behind the Core protocols. Two
    /// transcribers with DIFFERENT needs (dual-answer spec P0):
    /// - `_transcriber` (FINAL pass): high-accuracy `large-v3-turbo`; prefers a cached model so the
    ///   post-call pass is fast + non-blocking, upgrading to turbo once it's downloaded in the background.
    /// - `_liveTranscriber` (LIVE rolling path): small, always-cached `openai_whisper-base`, built
    ///   `allowDownload:false` so a live transcript is INSTANT and NEVER gated on a 954MB download (the
    ///   stall that once left it blank). Both are CACHED singletons — the model loads once and is reused.
    /// FINAL pass: high-accuracy turbo, but load path is CACHED-ONLY (`allowDownload:false`) so it can
    /// never block on the 954MB fetch (that happens in the background via `ensureFinalTranscriptionModel`).
    /// `unloadAfterEach:true` → the model loads for the pass then releases, so it never stays resident and
    /// each pass re-resolves (upgrading base→turbo once the background download lands).
    private let _transcriber = WhisperKitTranscriber(
        model: "openai_whisper-large-v3_turbo_954MB",
        fallbacks: ["openai_whisper-base", "openai_whisper-tiny"],
        allowDownload: false, unloadAfterEach: true,
        // Bias the final (saved) transcript toward the user's crypto/company glossary, read fresh each
        // pass so a just-edited glossary takes effect immediately.
        biasPrompt: { CorrectionDictionary.load().biasPrompt() })
    /// LIVE path: small `base`; may bootstrap-download its own small model on a fresh machine but never a
    /// large one. Stays warm across the call's ticks; released at record-stop via `releaseLiveTranscriptionModel`.
    private let _liveTranscriber = WhisperKitTranscriber(
        model: "openai_whisper-base", fallbacks: ["openai_whisper-tiny"], allowDownload: true,
        // Bias the LIVE in-call partials toward the learned glossary too (was unbiased — only the final
        // pass was), so in-call names/jargon read right as you go.
        biasPrompt: { CorrectionDictionary.load().biasPrompt() })
    private let _diarizer = FluidAudioDiarizer()
    var transcription: TranscriptionPipeline {
        TranscriptionPipeline(transcriber: _transcriber, diarizer: _diarizer)
    }
    /// LIVE transcription model (T1): the default `base` is fast; "more accurate" uses `small.en`, which
    /// reads real calls notably better but is heavier (~240MB, more CPU). Chosen in Settings, read fresh so
    /// a change applies to the NEXT recording. NOTE: the SAVED transcript always uses `large-v3-turbo`; this
    /// only affects the live in-call view (and Meet calls use captions instead — T2).
    static let liveAccurateKey = "callbrain.liveTranscriptionAccurate"
    var liveTranscriptionAccurate: Bool { UserDefaults.standard.bool(forKey: Self.liveAccurateKey) }
    var liveTranscriptionModel: String {
        liveTranscriptionAccurate ? "openai_whisper-small.en" : "openai_whisper-base"
    }

    /// Prefer the crash-ISOLATED persistent helper (`cbtranscribe --serve`, warm model in a child
    /// process) so a live CoreML assertion kills the child, not the app mid-meeting. Recreated when the
    /// chosen live model changes; falls back to the in-process transcriber only when the helper binary
    /// can't be located (e.g. an un-bundled dev build).
    @ObservationIgnored private var _sidecarLiveTranscriber: SidecarLiveTranscriber?
    @ObservationIgnored private var _sidecarModel: String?
    var liveTranscriber: CallBrainCore.Transcriber {
        let model = liveTranscriptionModel
        if let s = _sidecarLiveTranscriber, _sidecarModel == model { return s }
        _sidecarLiveTranscriber?.shutdown()   // model changed → tear down the old warm child
        if let url = TranscriptionHelperLocator.helperURL() {
            let s = SidecarLiveTranscriber(executableURL: url, model: model)
            _sidecarLiveTranscriber = s; _sidecarModel = model
            return s
        }
        return _liveTranscriber   // in-process fallback (base; rare — un-bundled dev build)
    }

    /// Ensure the CURRENT live model is cached so the crash-isolated serve helper (cached-only) can load it.
    /// Background, best-effort; on a fresh machine (or right after switching to "accurate") the first call's
    /// live transcript may be blank until this lands (the post-call pass is unaffected). Tracks per-model so
    /// switching quality re-downloads the new one. Also call it when the Settings toggle flips.
    @ObservationIgnored private var _downloadedLiveModels: Set<String> = []
    @ObservationIgnored private var liveModelDownloadInFlight = false

    /// Live status of the CURRENT live-transcription model so Settings can show a one-click, automatic
    /// "Downloading… / Ready" state (F3: the accurate-model download used to be silent, so the first
    /// recording after flipping the toggle ran the standard model with no indication).
    enum LiveModelStatus: Sendable, Equatable { case ready, downloading, failed }
    private(set) var liveModelStatus: LiveModelStatus = .ready

    /// Ensure the CURRENT live model is downloaded, updating `liveModelStatus` so the UI reflects it
    /// automatically. Idempotent + safe to call on every Settings appear and on toggle. On @MainActor, so
    /// the observable status mutations are main-isolated.
    func ensureLiveTranscriptionModel() {
        guard TranscriptionHelperLocator.helperURL() != nil else { liveModelStatus = .ready; return }
        let model = liveTranscriptionModel
        // Already on disk (this session or a prior one) → ready immediately, no fetch.
        if _downloadedLiveModels.contains(model) || WhisperKitTranscriber.isModelCached(model) {
            _downloadedLiveModels.insert(model)
            liveModelStatus = .ready
            return
        }
        guard !liveModelDownloadInFlight else { return }
        liveModelDownloadInFlight = true
        liveModelStatus = .downloading
        Task { [weak self] in
            let ok = await WhisperKitTranscriber.ensureDownloaded(model)
            guard let self else { return }
            self.liveModelDownloadInFlight = false
            if ok { self._downloadedLiveModels.insert(model); self.liveModelStatus = .ready }
            else { self.liveModelStatus = .failed }
        }
    }

    /// Fetch the high-accuracy final-pass model in the background (best-effort, never blocks) so the
    /// post-call transcription upgrades to `large-v3-turbo` without a cold download in the load path.
    /// Kicked off at record-start; a stalled/offline fetch simply leaves the final pass on cached `base`
    /// and is retried on the next recording. `keep_alive`/residency don't apply — WhisperKit is on-device
    /// CoreML, not a server, and the final transcriber unloads itself after each pass.
    @ObservationIgnored private var finalModelDownloadInFlight = false
    @ObservationIgnored private var finalModelDownloaded = false
    func ensureFinalTranscriptionModel() {
        guard !finalModelDownloaded, !finalModelDownloadInFlight else { return }
        finalModelDownloadInFlight = true
        Task { [weak self] in
            let ok = await WhisperKitTranscriber.ensureDownloaded("openai_whisper-large-v3_turbo_954MB")
            self?.finalModelDownloadInFlight = false
            if ok { self?.finalModelDownloaded = true }   // failed → retried on the next record-start
        }
    }

    /// Release the warm LIVE transcription model (founder: nothing resident once a call ends). Called at
    /// record-stop; the final pass owns + releases its own model per-pass.
    func releaseLiveTranscriptionModel() {
        _liveTranscriber.unload()
        _sidecarLiveTranscriber?.shutdown()
    }

    /// The user's growing vocabulary corrections (crypto/company glossary + wrong→right). Observable for
    /// the editor + click-to-correct UI; persisted to UserDefaults, which the transcriber's ASR bias and
    /// the ingest apply-pass read fresh — so an edit takes effect on the next transcript immediately.
    var corrections = CorrectionDictionary.load()

    /// Mutate + persist the corrections in one immutable step.
    func updateCorrections(_ transform: (CorrectionDictionary) -> CorrectionDictionary) {
        corrections = transform(corrections)
        corrections.save()
    }

    /// Meeting-note templates (Granola Phase C) that shape the AI notes structure. Observable for the
    /// pickers/editor; persisted to UserDefaults.
    var noteTemplates = NoteTemplateLibrary.load()

    func updateTemplates(_ transform: (NoteTemplateLibrary) -> NoteTemplateLibrary) {
        noteTemplates = transform(noteTemplates)
        noteTemplates.save()
    }

    /// Add ONE correction AND retroactively fix the OLD calls that already contain it (#42 / TC5), so
    /// keyword + semantic search over the back catalogue catch up.
    func addCorrection(_ entry: CorrectionEntry) {
        updateCorrections { $0.upserting(entry) }
        Task { await recorrectLibrary(forTerms: [entry.wrong]) }
    }

    /// Add a batch of corrections (e.g. approved AI-mined ones) + retroactively fix the affected calls.
    func addCorrections(_ entries: [CorrectionEntry]) {
        guard !entries.isEmpty else { return }
        updateCorrections { dict in entries.reduce(dict) { $0.upserting($1) } }
        Task { await recorrectLibrary(forTerms: entries.map(\.wrong)) }
    }

    /// True while a library-wide re-correction sweep is running (drives the Settings button state).
    /// Observable (NOT @ObservationIgnored) so the button reflects progress.
    private(set) var recorrectingLibrary = false

    /// Retroactively re-apply the current corrections to STORED transcripts so OLD calls become
    /// searchable under the corrected terms (#42 / TC5). Keyword search (FTS) corrects the instant the
    /// text is rewritten; the changed chunks are re-embedded in the background so semantic/AI search
    /// catches up too. `forTerms` given → target ONLY the calls containing those terms (fast, incremental
    /// — used when a correction is added); nil → the whole library (the Settings "Re-correct" sweep).
    /// Returns the number of chunks changed. Store work runs off-main.
    /// Surfaced when a re-correction sweep FAILS (so a failed data mutation isn't invisible — audit MED).
    private(set) var recorrectError: String?

    @discardableResult
    func recorrectLibrary(forTerms terms: [String]? = nil) async -> Int {
        let store = self.store, space = self.space
        let applicator = corrections.makeApplicator()
        // recorrectTranscripts enqueues the changed chunks for re-embedding INSIDE its own transaction,
        // so text/FTS and the embed-IOU can't diverge (audit HIGH). We just drain afterward.
        let outcome: Result<Int, Error> = await Task.detached(priority: .utility) {
            do {
                let scope: [String]?
                if let terms {
                    var set = Set<String>()
                    for t in terms { set.formUnion((try? store.meetingIDsContaining(t)) ?? []) }
                    if set.isEmpty { return .success(0) }   // nothing in the library contains these terms
                    scope = Array(set)
                } else {
                    scope = nil   // whole library
                }
                let result = try store.recorrectTranscripts(meetingIDs: scope, applicator: applicator, space: space)
                return .success(result.chunks)
            } catch { return .failure(error) }
        }.value
        switch outcome {
        case .success(let changed):
            recorrectError = nil
            if changed > 0 { drainPendingEmbeddings() }   // re-embed corrected chunks in the background
            return changed
        case .failure(let error):
            Logger(subsystem: "com.callbrain", category: "corrections")
                .error("recorrectLibrary failed: \(error.localizedDescription, privacy: .public)")
            recorrectError = error.localizedDescription
            return 0
        }
    }

    /// The Settings "Re-correct my whole library" one-shot sweep (single-flight).
    func recorrectEntireLibrary() {
        guard !recorrectingLibrary else { return }
        recorrectingLibrary = true
        Task {
            _ = await recorrectLibrary(forTerms: nil)
            recorrectingLibrary = false
        }
    }

    func meetingCount() -> Int { (try? store.meetingCount()) ?? 0 }
    func openTaskCount() -> Int { (try? store.openTaskCount()) ?? 0 }
    func recentMeetings() -> [Store.MeetingRow] { (try? store.recentMeetings()) ?? [] }

    /// Cached counts for the menu-bar surface, refreshed OFF-MAIN by `refreshReminders()` (called after
    /// every mutation) — so MenuBarView's body never does a synchronous COUNT read on the main thread (audit).
    private(set) var meetingCountCached = 0
    private(set) var openTaskCountCached = 0

    /// Bumps when a call's AI title/summary lands, so meeting lists can live-refresh.
    var titlesRevision = 0

    /// Generate (or refresh) the AI title + one-line summary for a call, then persist it. Async core.
    @discardableResult
    func runTitleIntelligence(for meetingID: String, force: Bool = false) async -> Bool {
        guard !isLocalOnly else { return false }   // F1: AI title uses the cloud — skip in local-only mode
        let store = self.store
        guard let m = await Task.detached(operation: { try? store.meeting(id: meetingID) }).value else { return false }
        if !force, m.aiTitle?.isEmpty == false { return false }
        let text = await Task.detached {   // read + join OFF the main thread (background AI pass, still on @MainActor)
            ((try? store.utterances(meetingID: meetingID)) ?? [])
                .map { ($0.speaker.map { "\($0): " } ?? "") + $0.text }.joined(separator: "\n")
        }.value
        guard let r = await TitleIntelligence(llm: router).generate(from: text, fallbackTitle: m.title) else { return false }
        await Self.loggedWrite("setMeetingIntelligence") { try store.setMeetingIntelligence(id: meetingID, aiTitle: r.title, aiSummary: r.summary) }
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
        let store = self.store
        Task { [weak self] in
            let rows = await Task.detached { (try? store.recentMeetings()) ?? [] }.value   // read off-main
            guard let self else { return }
            for m in rows where (m.aiTitle?.isEmpty ?? true) {
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
    /// Typed outcome so the UI can tell an ENGINE failure (Ollama down + no CLI → show a "set up your
    /// engine" banner) apart from a benign no-content case (don't alarm the user). Audit MED.
    enum SummaryOutcome: Sendable { case ok, noContent, engineUnavailable, persistFailed }

    @discardableResult
    func generateCallSummary(for meetingID: String, preferCloud: Bool = false) async -> SummaryOutcome {
        let store = self.store
        guard let m = await Task.detached(operation: { try? store.meeting(id: meetingID) }).value else { return .noContent }
        // Every call gets a concise Summary-tab digest — including Gemini calls (we summarize Google's notes
        // into a short digest; the full notes stay on the Transcript tab). Founder ask 2026-06-30: tabs on
        // every call. The transcript read + join run OFF the main thread (background pass on @MainActor).
        let text = await Task.detached { () -> String in
            let utts = (try? store.utterances(meetingID: meetingID)) ?? []
            let t = utts.map { ($0.speaker.map { "\($0): " } ?? "") + $0.text }.joined(separator: "\n")
            if !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return t }
            // Older rows store transcript_chunks but no utterances — fall back to those so they still summarize.
            return ((try? store.transcript(meetingID: meetingID)) ?? [])
                .map { ($0.speaker.map { "\($0): " } ?? "") + $0.text }.joined(separator: "\n")
        }.value
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .noContent }

        // Local-first chain: the small routine model → cloud as a last resort if Ollama is unavailable.
        // `preferCloud` (the "Regenerate with AI" button) goes straight to the premium CLI pass (Opus).
        let profile = PersonalProfile.load()   // summaries gloss jargon for HIM too (Task 1.4)
        // Local-only mode (F1): NEVER fall back to the cloud CLI — Ollama or nothing — so a private call's
        // full transcript never egresses. Otherwise local-first with a cloud last resort; the "Regenerate
        // with AI" button (preferCloud) goes straight to the premium cloud pass.
        let summarizers: [any Summarizer]
        if isLocalOnly {
            summarizers = [OllamaSummarizer(model: localSummaryModel, profile: profile)]
        } else if preferCloud {
            summarizers = [CLISummarizer(llm: router, model: "opus", profile: profile)]
        } else {
            summarizers = [OllamaSummarizer(model: localSummaryModel, profile: profile),
                           CLISummarizer(llm: router, model: "sonnet", profile: profile)]
        }
        var result: CallSummary?
        for s in summarizers { if let r = await s.summarize(transcript: text, title: m.displayTitle) { result = r; break } }
        guard let r = result else { return .engineUnavailable }   // Ollama down AND CLI failed → real engine failure
        // Refresh the call's to-dos idempotently (replaces prior OPEN summary tasks, keeps completed ones)
        // so a Regenerate doesn't accumulate reworded duplicates. All writes OFF the main thread.
        let items = r.actionItems
            .map { ActionItemDraft(owner: $0.owner, text: String($0.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(280))) }
            .filter { !$0.text.isEmpty }
        // Summary + its action items commit ATOMICALLY (audit B1) — a tasks-write failure must not
        // leave a summarized-looking call (→ no auto-retry) with its action items silently dropped.
        let persisted = await Task.detached { () -> Bool in
            do { try store.setSummaryAndTasks(meetingID: meetingID, summary: r.summary,
                                              source: r.source, items: items); return true }
            catch { return false }
        }.value
        guard persisted else { return .persistFailed }
        refreshReminders(); titlesRevision &+= 1
        if !isLocalOnly { corpus.scheduleSync() }   // export finalized call (skipped in local-only: no egress)
        return .ok
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

    /// The user's configured ventures (from Settings). Cached; call `reloadVentures()` after an edit so the
    /// classifier + venture filter bar pick up changes without a relaunch.
    private(set) var ventures: [Venture] = VentureConfig.load()
    func reloadVentures() {
        ventures = VentureConfig.load()
        titlesRevision &+= 1
        // F4: re-tag the WHOLE library on a venture edit (the old code only classified NULL-category calls,
        // so adding a venture never rescued calls already auto-tagged "other" whose keywords now match).
        // Done OFF-main (clearAutoCategories is a full-table write) and HEURISTIC-ONLY — a bulk re-tag must
        // NOT fire the ~90s local-LLM tiebreaker per call (audit: that was hundreds of serial LLM calls on
        // every venture edit). New imports still get the LLM tiebreaker via classifyInBackground.
        if !ventures.isEmpty { reclassifyAllHeuristic(clearFirst: true) }
    }

    /// Bulk re-tag every non-manual call against the current ventures using the HEURISTIC ONLY (no LLM
    /// escalation), entirely off-main. Used after a venture edit so re-tagging the whole library is instant
    /// and deterministic (audit F4). `clearFirst` NULLs existing auto tags first so every non-manual call is
    /// re-evaluated (manual picks are always preserved by `setAutoCategory`'s `category_manual = 0` guard).
    func reclassifyAllHeuristic(clearFirst: Bool = false) {
        let store = self.store
        let snapshot = ventures
        guard !snapshot.isEmpty else { return }
        Task.detached { [weak self] in
            if clearFirst { _ = try? store.clearAutoCategories() }
            let ids = (try? store.meetingsNeedingCategory()) ?? []
            let heuristic = CategoryHeuristic(ventures: snapshot)
            let valid = Set(snapshot.map(\.id) + [kOtherVentureID])
            for id in ids {
                guard let m = try? store.meeting(id: id), !m.categoryManual else { continue }
                let utts = (try? store.utterances(meetingID: id)) ?? []
                let people = ((try? store.entities(meetingID: id)) ?? []).filter { $0.kind == .person }.map(\.name)
                let body = utts.prefix(80).map(\.text).joined(separator: " ")
                let signal = [m.displayTitle, m.title, m.aiSummary ?? "", m.callSummary ?? "",
                              people.joined(separator: " "), body].joined(separator: "\n")
                let r = heuristic.classify(signal)
                let category = valid.contains(r.category) ? r.category : kOtherVentureID
                try? store.setAutoCategory(id: id, category: category, confidence: r.confidence)
            }
            await MainActor.run { self?.titlesRevision &+= 1 }
        }
    }

    /// Heuristic-first, with a local-LLM tiebreaker only for genuinely ambiguous calls (free + private).
    private var categoryEngine: CategoryEngine { CategoryEngine(ventures: ventures) }
    @ObservationIgnored private var pendingCategory: [String] = []
    @ObservationIgnored private var categoryDraining = false

    /// Classify one call into its venture and persist it. Skips calls the user categorized by hand.
    @discardableResult
    func classifyCategory(for meetingID: String) async -> Bool {
        let store = self.store
        // Build the classification signal OFF the main thread (meeting + utterances + entities reads).
        let signal: String? = await Task.detached { () -> String? in
            guard let m = try? store.meeting(id: meetingID), !m.categoryManual else { return nil }
            let utts = (try? store.utterances(meetingID: meetingID)) ?? []
            let people = ((try? store.entities(meetingID: meetingID)) ?? [])
                .filter { $0.kind == .person }.map(\.name)
            let body = utts.prefix(80).map(\.text).joined(separator: " ")
            return [m.displayTitle, m.title, m.aiSummary ?? "", m.callSummary ?? "",
                    people.joined(separator: " "), body].joined(separator: "\n")
        }.value
        guard let signal else { return false }
        // Audit #4: with NO ventures configured, don't persist a bogus "other" tag — leave the call
        // UNCATEGORIZED so it's classified for real once the user adds ventures (reloadVentures backfills).
        let snapshot = ventures
        guard !snapshot.isEmpty else { return false }
        let r = await CategoryEngine(ventures: snapshot).categorize(text: signal)
        // Audit #7: the classify (esp. the ~90s LLM path) can outlive a venture deletion. Only persist a
        // category that is STILL valid against the CURRENT config; a since-deleted venture folds to "other".
        let valid = Set(ventures.map(\.id) + [kOtherVentureID])
        guard !ventures.isEmpty else { return false }   // config emptied mid-flight → leave uncategorized
        let category = valid.contains(r.category) ? r.category : kOtherVentureID
        await Self.loggedWrite("setAutoCategory") { try store.setAutoCategory(id: meetingID, category: category, confidence: r.confidence) }
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
        let store = self.store
        Task { [weak self] in
            let ids = await Task.detached { (try? store.meetingsNeedingCategory()) ?? [] }.value   // read off-main
            for id in ids { self?.classifyInBackground(id) }
        }
    }

    /// User picked a category by hand — pinned (auto-classification won't overwrite it).
    /// User rename of a call (off-main). Empty string clears the override → back to the original/auto title.
    func renameMeeting(_ meetingID: String, to title: String) async {
        let store = self.store
        let updated = await Self.loggedWrite("setMeetingTitle", {
            try store.setMeetingTitle(id: meetingID, title: title)
        })
        if updated {
            titlesRevision &+= 1
        }
    }

    func setCategoryManual(_ meetingID: String, _ category: String) async {
        let store = self.store, raw = category
        let updated = await Self.loggedWrite("setCategory", {
            try store.setCategory(id: meetingID, category: raw, confidence: 1.0, manual: true)
        })
        if updated {
            titlesRevision &+= 1
        }
    }

    struct ReconcileSummary: Sendable { let reworded: Int; let completed: Int; let deduped: Int; let added: Int
        var coveredAllCalls = true }   // false when the corpus exceeded the batch cap (reviewed most-recent N)

    /// "Tidy with AI" — reconcile the whole task list against every call: reword for clarity, mark ones the
    /// calls show are done, merge duplicates, add missed tasks. Safe: completion/dedup mark Done
    /// (reversible), additions are FK-checked to a real call, nothing is hard-deleted.
    func reconcileTasks() async -> ReconcileSummary? {
        guard !isLocalOnly else { return nil }   // F1: Tidy sends transcripts to the cloud — disabled in local-only
        let store = self.store
        let founder = FounderIdentity.displayName
        // Build the task context + per-call evidence OFF the main thread. Reads OPEN tasks (to tidy) AND DONE
        // tasks (so Tidy never re-surfaces something already handled), and batches EVERY call's utterances
        // into ~13k-char chunks so it examines the whole corpus, not just the first 20 (founder 2026-07-01).
        let prep = await Task.detached { () -> (open: [TaskIntelligence.TaskContext], resolved: [TaskIntelligence.TaskContext], batches: [String], openIDs: Set<String>, validIDs: Set<String>, existingTexts: [String]) in
            let openRows = (try? store.tasks(status: .open)) ?? []
            let doneRows = (try? store.tasks(status: .done)) ?? []
            func ctx(_ rows: [Store.TaskRow]) -> [TaskIntelligence.TaskContext] {
                rows.map { .init(id: $0.item.id, owner: $0.item.owner, text: $0.item.text, meeting: $0.meetingTitle) }
            }
            let meetings = (try? store.recentMeetings()) ?? []
            var batches: [String] = []; var cur = ""
            for m in meetings {
                let utts = (try? store.utterances(meetingID: m.id)) ?? []
                let body = utts.map { ($0.speaker.map { "\($0): " } ?? "") + $0.text }.joined(separator: "\n")
                let block = "## CALL meetingID=\(m.id) — \(m.displayTitle) (\(m.date))\n" + String(body.prefix(2500)) + "\n\n"
                if !cur.isEmpty, cur.count + block.count > 13000 { batches.append(cur); cur = "" }
                cur += block
            }
            if !cur.isEmpty { batches.append(cur) }
            return (ctx(openRows), ctx(doneRows), batches, Set(openRows.map(\.item.id)),
                    Set(meetings.map(\.id)), openRows.map(\.item.text) + doneRows.map(\.item.text))
        }.value
        guard !prep.batches.isEmpty || !prep.open.isEmpty else { return nil }

        // Reconcile each batch (each pass sees the FULL open + resolved lists). Batches are most-recent-
        // first (recentMeetings is date-DESC), so the cap always covers the MOST RELEVANT recent calls.
        // Capped to bound cost/latency on a huge corpus — but NEVER silently: if the corpus exceeds the cap
        // we log it and tell the founder Tidy reviewed the most-recent N (no silent truncation). Ongoing
        // scale is handled incrementally + free by the per-call auto-complete on ingest (completeMatchingTasks).
        let maxBatches = 24
        let coveredAllCalls = prep.batches.count <= maxBatches
        if !coveredAllCalls {
            Logger(subsystem: "com.callbrain", category: "tasks")
                .notice("Tidy: corpus is \(prep.batches.count, privacy: .public) batches; reviewing the \(maxBatches, privacy: .public) most-recent (per-call auto-complete keeps the rest current).")
        }
        let ti = TaskIntelligence(llm: router)
        var reword: [TaskIntelligence.Plan.Reword] = []; var complete = Set<String>()
        var duplicates = Set<String>(); var adds: [TaskIntelligence.Plan.New] = []
        for (i, batch) in prep.batches.prefix(maxBatches).enumerated() {
            guard let plan = await ti.reconcile(tasks: prep.open, resolved: prep.resolved, evidence: batch, founder: founder) else {
                // If we can't even reach the AI on the FIRST batch, stop — don't spawn N more doomed
                // per-batch calls (each up to the reconcile timeout, ×2 on provider fallback). That
                // cascade was the "Tidy bogs down / hangs". A nil after some successes is just one skipped
                // batch. Returning nil surfaces "Couldn't reach the AI to tidy tasks — try again."
                if i == 0 { return nil }
                continue
            }
            reword.append(contentsOf: plan.reword); complete.formUnion(plan.complete)
            duplicates.formUnion(plan.duplicates); adds.append(contentsOf: plan.add)
        }
        guard !reword.isEmpty || !complete.isEmpty || !duplicates.isEmpty || !adds.isEmpty else {
            return ReconcileSummary(reworded: 0, completed: 0, deduped: 0, added: 0, coveredAllCalls: coveredAllCalls)
        }

        // Apply the merged plan OFF the main thread. The dedup GUARD is what actually prevents a DONE task
        // from being re-added, even if the model slips past the prompt rule (founder: "no rehighlighting old
        // shit I already did").
        let openIDs = prep.openIDs, validIDs = prep.validIDs, initialTexts = prep.existingTexts
        let finalReword = reword, finalComplete = complete, finalDuplicates = duplicates, finalAdds = adds
        let result = await Task.detached { () -> ReconcileSummary in
            var rew = 0, comp = 0, dedup = 0, added = 0
            var existingTexts = initialTexts, rewordedIDs = Set<String>()
            func clean(_ s: String?, max: Int) -> String? {
                guard let s else { return nil }
                let t = s.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return t.isEmpty ? nil : String(t.prefix(max))
            }
            // Count ONLY writes that actually succeeded — the counters used to increment even when
            // the DB write threw or changed zero rows, so the UI reported a tidy that didn't happen
            // (audit B2).
            for u in finalReword where openIDs.contains(u.id) && !rewordedIDs.contains(u.id) {
                guard let text = clean(u.text, max: 280) else { continue }
                if (try? store.updateTaskText(id: u.id, text: text, owner: clean(u.owner, max: 80))) != nil {
                    rew += 1; rewordedIDs.insert(u.id)
                }
            }
            for id in finalComplete where openIDs.contains(id) {
                if (try? store.setTaskStatus(id: id, .done)) == true { comp += 1 }
            }
            for id in finalDuplicates where openIDs.contains(id) {
                if (try? store.setTaskStatus(id: id, .done)) == true { dedup += 1 }
            }
            for n in finalAdds where validIDs.contains(n.meetingID) {
                guard let text = clean(n.text, max: 280) else { continue }
                if TaskIntelligence.isNearDuplicate(text, of: existingTexts) { continue }   // 5c: never resurface
                if (try? store.addReconciledTask(meetingID: n.meetingID, owner: clean(n.owner, max: 80), text: text)) == true {
                    added += 1; existingTexts.append(text)                                  // so a later batch can't re-add it
                }
            }
            return ReconcileSummary(reworded: rew, completed: comp, deduped: dedup, added: added, coveredAllCalls: coveredAllCalls)
        }.value
        refreshReminders()
        return result
    }

    /// Delete a call and everything derived from it (chunks/embeddings/utterances/entities/tasks +
    /// meeting-scoped chats, with citations to it scrubbed from other chats). Refreshes the reminder
    /// since open-task counts may change. Returns false on failure (surfaced in the UI).
    @discardableResult
    func deleteMeeting(_ id: String) -> Bool {
        do {
            try store.deleteMeeting(id: id); refreshReminders(); meetingChats[id] = nil
            // F14: a corpus pass prunes the deleted call's exported file locally, and the local removal makes
            // the sync agent rsync --delete it off the server too (a deleted call is often a sensitive one).
            if !isLocalOnly { corpus.scheduleSync() }
            return true
        } catch { return false }
    }

    /// Off-main delete: the cascade + citation scrub (multi-statement) and the reminder count read run OFF
    /// the main thread so deleting a call never freezes the list (audit HIGH). Returns success on the main actor.
    func deleteMeetingAsync(_ id: String) async -> Bool {
        let store = self.store
        let ok = await Task.detached { do { try store.deleteMeeting(id: id); return true } catch { return false } }.value
        guard ok else { return false }
        meetingChats[id] = nil
        refreshReminders()            // updates cached counts + reminder off-main
        if !isLocalOnly { corpus.scheduleSync() }   // F14: propagate the delete to the corpus (local + server)
        return true
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

    /// "Go full screen" from a call's docked AskFred: carry that conversation into the global Ask tab so the
    /// user doesn't lose it. Re-parents the conversation to global (meeting_id = NULL) — off-main — so it now
    /// lives in the Ask-tab Recents and future questions search ALL calls (the point of going "full"), then
    /// loads it into `askChat`. Returns false if there's no conversation yet (nothing to carry).
    @discardableResult
    func promoteMeetingChatToAsk(_ meetingID: String) async -> Bool {
        let mChat = meetingChat(meetingID)
        // Don't clobber in-flight work (audit MED×2): bail if the docked chat is still generating (its latest
        // answer isn't persisted yet → a stale snapshot) or the global Ask chat is mid-answer (load() would
        // cancel + discard it). The button is also disabled while the docked chat is busy.
        guard !mChat.busy, !askChat.busy, let cid = mChat.conversationID else { return false }
        let store = self.store
        let conv = await Task.detached { () -> Conversation? in
            guard var c = try? store.conversation(id: cid) else { return nil }
            c.meetingID = nil
            try? store.upsertConversation(c)          // re-parent to global (messages are keyed separately)
            return try? store.conversation(id: cid)
        }.value
        guard let conv else { return false }
        askChat.load(conv, self)
        // Evict the docked model (audit HIGH): otherwise it keeps conversationID == cid and would write
        // meeting-scoped answers into the now-GLOBAL conversation. A fresh open starts a new call-scoped chat.
        meetingChats[meetingID] = nil
        return true
    }

    /// Re-arm the daily reminder with the current open-task count — call whenever tasks change (completed,
    /// imported, or a meeting deleted) so a scheduled notification never fires a stale count (P6 gate MED).
    /// Re-arm the daily reminder AND refresh the cached menu-bar counts — the two COUNT reads run OFF the
    /// main thread (audit: no synchronous SQLite on main). Fire-and-forget; safe to call from anywhere.
    func refreshReminders() {
        let store = self.store
        Task { [weak self] in
            let (m, t) = await Task.detached {
                ((try? store.meetingCount()) ?? 0, (try? store.openTaskCount()) ?? 0)
            }.value
            guard let self else { return }
            self.meetingCountCached = m
            self.openTaskCountCached = t
            NotificationManager.refresh(openTaskCount: t)
        }
    }

    // MARK: - backup / restore (Phase 8)

    func backup(to url: URL) throws { try store.backup(to: url) }

    /// Stage a `.cbk` to be swapped in on next launch (a live DB can't be replaced under itself).
    /// Returns false if the file isn't a valid Recap backup.
    func stageRestore(from url: URL) -> Bool {
        guard Store.isValidBackup(at: url) else { return false }
        let pending = dbPath + ".pending-restore"
        try? FileManager.default.removeItem(atPath: pending)
        do { try FileManager.default.copyItem(at: url, to: URL(fileURLWithPath: pending)); return true }
        catch { return false }
    }

    /// Off-main restore staging — the .cbk validity check (opens SQLite) + the full-file copy run OFF the
    /// main thread so restoring a large backup doesn't beachball the window (audit HIGH — matches backup()).
    func stageRestoreAsync(from url: URL) async -> Bool {
        let pending = dbPath + ".pending-restore"
        return await Task.detached {
            guard Store.isValidBackup(at: url) else { return false }
            try? FileManager.default.removeItem(atPath: pending)
            do { try FileManager.default.copyItem(at: url, to: URL(fileURLWithPath: pending)); return true }
            catch { return false }
        }.value
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

private enum ExtensionPairingTokenReadResult {
    case found(String)
    case missing
    case failed(OSStatus)
}

private enum ExtensionPairingTokenSaveResult {
    case saved
    case duplicate
    case failed(OSStatus)
}

private final class ProcessTokenCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cached: String?

    func token(make: () -> String) -> String {
        lock.withLock {
            if let cached {
                return cached
            }
            let token = make()
            cached = token
            return token
        }
    }
}
