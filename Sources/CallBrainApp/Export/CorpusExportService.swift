import Foundation
import AppKit
import CallBrainCore
import CallBrainAppCore

/// App-layer wrapper around `CorpusExportEngine` (Part B): owns the enable flag + destination folder
/// (`UserDefaults`, plain path — the app is unsandboxed so no security-scoped bookmark is needed), a
/// debounced trigger that coalesces a burst of updates into one pass, published status for Settings, and
/// the "Reveal in Finder" affordance. The heavy work runs OFF the main thread.
@MainActor
@Observable
final class CorpusExportService {

    struct Status: Equatable {
        var enabled = false
        var folderPath: String?
        var exportedCount = 0
        var lastExport: Date?
        var isExporting = false
        var lastError: String?
    }
    private(set) var status = Status()

    static let enabledKey = "callbrain.corpus.enabled"
    static let folderKey = "callbrain.corpus.folder"

    private let store: Store
    private let defaultFolder: URL
    private let defaults: UserDefaults

    private var isRunning = false
    private var pendingRerun = false
    private var pendingVerify = false
    private var debounceTask: Task<Void, Never>?

    init(store: Store, defaultFolder: URL, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaultFolder = defaultFolder
        self.defaults = defaults
        refreshStatus()
    }

    // MARK: Config

    var isEnabled: Bool { defaults.bool(forKey: Self.enabledKey) }

    /// The user-chosen folder, or the default (`<app-support>/Recap/corpus`, which the sync layer pushes).
    var folderURL: URL {
        if let path = defaults.string(forKey: Self.folderKey), !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return defaultFolder
    }

    /// Local-only mode (Settings) — the corpus sync LaunchAgent rsyncs the folder to a REMOTE Mac, which IS
    /// egress. While local-only is on we never install/keep that agent and never export, so "nothing leaves
    /// this Mac" holds even with corpus enabled (audit F1 HIGH: gating the in-app scheduleSync calls alone
    /// was insufficient — the LaunchAgent syncs on its own). Read live so it self-heals on the next trigger.
    private var localOnlyActive: Bool { defaults.bool(forKey: AppEnvironment.localOnlyKey) }

    func setEnabled(_ on: Bool) {
        defaults.set(on, forKey: Self.enabledKey)
        refreshStatus()
        if on && !localOnlyActive {
            installSync()   // set up the auto-sync LaunchAgent (rsync → server Mac)
            scheduleSync()
        } else {
            CorpusSyncInstaller.uninstall()
        }
    }

    /// Reconcile the sync agent when local-only mode is toggled: uninstall it (no egress) when local-only
    /// turns on, or reinstall + catch up when it turns off and corpus is still enabled.
    func reconcileLocalOnly() async {
        if localOnlyActive { CorpusSyncInstaller.uninstall() }
        else { await reconcileOnLaunch() }
    }

    func setFolder(_ url: URL) {
        defaults.set(url.path, forKey: Self.folderKey)
        refreshStatus()
        if isEnabled {
            installSync()   // re-point the sync at the new source folder
            scheduleSync()
        }
    }

    /// (Re)install the sync LaunchAgent for the current folder. Failures surface in status but never block
    /// local export — the founder still gets the files even if the auto-sync couldn't be set up.
    private func installSync() {
        guard !localOnlyActive else { CorpusSyncInstaller.uninstall(); return }   // no remote egress in local-only
        do { try CorpusSyncInstaller.install(corpusFolder: folderURL, defaults: defaults) }
        catch { status.lastError = "Couldn't set up auto-sync: \(error.localizedDescription)" }
    }

    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([folderURL])
    }

    private func refreshStatus() {
        status.enabled = isEnabled
        status.folderPath = folderURL.path
    }

    // MARK: Triggers

    /// Coalesce a burst of updates (re-summarize + notes + reclassify) into ONE pass ~2 s later.
    func scheduleSync() {
        guard isEnabled, !localOnlyActive else { return }
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled else { return }
            await self.exportChanged()
        }
    }

    /// Incremental pass (cheap skip). Called from the debounced trigger + the launch backfill.
    func exportChanged() async { await run(verify: false) }

    /// On launch: if enabled, (re)install the sync LaunchAgent (self-heals a removed agent) and run a
    /// catch-up export. No-ops when disabled.
    func reconcileOnLaunch() async {
        guard isEnabled else { return }
        guard !localOnlyActive else { CorpusSyncInstaller.uninstall(); return }   // local-only: remove any agent
        installSync()
        await exportChanged()
    }

    /// Full verify/self-heal pass — rewrites any file whose on-disk export_hash drifted. ("Export all now".)
    func exportAll(force: Bool) async { await run(verify: force) }

    private func run(verify: Bool) async {
        guard isEnabled, !localOnlyActive else { return }   // paused entirely in local-only (no writes, no egress)
        if isRunning {
            // A run is in flight — fold this trigger into a rerun, keeping the STRONGER (verify) mode so a
            // manual "Export all now" is never downgraded to a cheap pass behind an incremental run.
            pendingRerun = true
            pendingVerify = pendingVerify || verify
            return
        }
        isRunning = true
        status.isExporting = true

        let folder = folderURL
        let store = self.store
        let now = Date()
        let outcome: Result<Int, Error> = await Task.detached {
            do { return .success(try CorpusExportEngine.run(store: store, folder: folder, verify: verify, now: now)) }
            catch { return .failure(error) }
        }.value

        switch outcome {
        case .success(let count):
            status.exportedCount = count
            status.lastExport = now
            status.lastError = nil
        case .failure(let error):
            status.lastError = error.localizedDescription
        }
        status.isExporting = false
        isRunning = false
        if pendingRerun {
            pendingRerun = false
            let verifyNext = pendingVerify
            pendingVerify = false
            await run(verify: verifyNext)
        }
    }
}
