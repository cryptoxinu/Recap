import Foundation
import AppKit
import CallBrainCore

/// Auto-imports Fathom calls by polling the Fathom public API (api.fathom.ai) — connect once with a free
/// API key, then it pulls every new call in the background (transcript + attendees), runs it through the
/// same ingest/dedupe/title/summary/categorize pipeline, and keeps a watermark so each poll only fetches
/// what's new. No external infra, no per-call step.
///
/// Reliability (audit-hardened): the watermark NEVER advances past a call whose transcript isn't ready yet
/// or past an un-drained page, a backlog drains across polls via a persisted resume cursor, one bad call
/// can't block the rest, and a disconnect mid-sync can't resurrect cleared credentials.
@MainActor
@Observable
final class FathomConnect {
    private unowned let env: AppEnvironment
    private let store: any FathomCredentialStore = KeychainFathomStore()
    private let client: FathomClient

    private(set) var connected: Bool
    private(set) var syncing = false
    private(set) var status = ""
    private(set) var lastSyncCount = 0

    @ObservationIgnored private var autoSyncTask: Task<Void, Never>?
    // Written only in init (main actor), read only in deinit (no concurrent access then).
    @ObservationIgnored nonisolated(unsafe) private var foregroundObserver: NSObjectProtocol?
    @ObservationIgnored private var lastForegroundSync = Date.distantPast
    /// Bumped on every connect/disconnect/reconcile transition. An in-flight `syncNow` (or an off-main
    /// reconcile) captures it and bails the instant it changes — so we detect a disconnect WITHOUT a
    /// (slow, main-thread) Keychain read, and a stale launch-reconcile can't clobber a fresh connect.
    @ObservationIgnored private var connGen = 0
    private static let seenKey = "callbrain.fathomSeenIDs"
    private static let cursorKey = "callbrain.fathomResumeCursor"
    private static let connectedKey = "callbrain.fathomConnected"   // cached so launch never reads the Keychain
    private static let seenCap = 6000
    /// Steady-state we re-scan a window back from the last FULL sync — wide enough to cover a transcript
    /// that wasn't ready yet AND any time the app was closed. The seen-id set (+ ingest content-dedupe) is
    /// the source of truth for "already imported", so re-scanning is free of duplicates; this window only
    /// bounds how far back we look.
    private static let window: TimeInterval = 3 * 86_400

    init(env: AppEnvironment) {
        self.env = env
        self.client = FathomClient(store: store)
        // Read the cached flag (instant) — NEVER the Keychain on the launch path (a Keychain read can take
        // seconds on an unsigned build and would beachball the whole app on open).
        self.connected = UserDefaults.standard.bool(forKey: Self.connectedKey)
        if connected {
            Task { [weak self] in await self?.syncNow() }   // its Keychain access is off the main thread
            startAutoSync()
        }
        // Pull the moment you bring CallBrain to the front — so right after a meeting, opening the app
        // imports the new call immediately, without leaning on the timer.
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onForeground() }
        }
        // Existing users connected BEFORE this flag existed have an API key in the Keychain but no cached
        // flag yet. Read the real Keychain OFF-MAIN and self-heal the flag (kicking the catch-up sync if it
        // flips us connected). Keeps launch instant while staying honest about the real connection state.
        let store = self.store
        let gen = connGen
        Task.detached { [weak self] in
            let real = !((store.load()?.apiKey).map { $0.isEmpty } ?? true)
            await self?.reconcileConnected(real, gen: gen)
        }
    }

    deinit { if let o = foregroundObserver { NotificationCenter.default.removeObserver(o) } }

    /// Reconcile the cached flag against the real Keychain (called off-main → hops back here on main).
    /// `gen` is the connection generation captured before the off-main read; if the user connected or
    /// disconnected meanwhile it will have changed, so we drop the now-stale snapshot (audit HIGH: race).
    private func reconcileConnected(_ real: Bool, gen: Int) {
        guard gen == connGen, real != connected else { return }
        setConnected(real)
        if real {
            startAutoSync(); Task { [weak self] in await self?.syncNow() }
        } else {
            autoSyncTask?.cancel(); autoSyncTask = nil    // drop a timer started from a stale cached `true`
        }
    }

    private func onForeground() {
        guard connected else { return }
        if Date().timeIntervalSince(lastForegroundSync) < 120 { return }   // debounce rapid focus changes
        lastForegroundSync = Date()
        Task { [weak self] in await self?.syncNow() }
    }

    var isConfigured: Bool { connected }

    private func setConnected(_ v: Bool) {
        connGen &+= 1                    // any transition invalidates in-flight syncs + stale reconciles
        connected = v
        UserDefaults.standard.set(v, forKey: Self.connectedKey)
    }

    /// Save + validate the API key, then connect and pull the first batch. All Keychain I/O is off-main.
    func connect(apiKey: String) async {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { status = "Paste your Fathom API key first."; return }
        let store = self.store
        let ok = await Task.detached {
            let last = store.load()?.lastSync
            return store.save(FathomCredentials(apiKey: key, lastSync: last)) && store.load()?.apiKey == key
        }.value
        guard ok else { status = "Couldn't save the key to your Keychain — try again."; return }
        status = "Checking your Fathom key…"
        do {
            _ = try await client.fetch(since: nil, startCursor: nil, maxPages: 1, pageSize: 1)   // validates
            setConnected(true)
            status = "Connected — importing your Fathom calls…"
            startAutoSync()
            await syncNow()
        } catch FathomError.unauthorized {
            await Task.detached { store.clear() }.value; setConnected(false)
            status = "That API key was rejected. Generate one at fathom.video → Settings → Integrations → API."
        } catch {
            setConnected(true); startAutoSync()      // key saved; transient network error → auto-sync retries
            status = "Saved — couldn't reach Fathom just now; it'll retry automatically."
        }
    }

    func disconnect() {
        autoSyncTask?.cancel(); autoSyncTask = nil
        let store = self.store
        Task.detached { store.clear() }   // Keychain delete off-main
        UserDefaults.standard.removeObject(forKey: Self.seenKey)
        UserDefaults.standard.removeObject(forKey: Self.cursorKey)
        setConnected(false)
        status = "Disconnected."
    }

    private func startAutoSync() {
        autoSyncTask?.cancel()
        autoSyncTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1800))   // background safety net every 30 min
                if Task.isCancelled { break }
                await self?.syncNow()
            }
        }
    }

    func syncNow() async {
        guard connected, !syncing else { return }
        syncing = true; defer { syncing = false }
        // Capture the connection generation BEFORE any await; `live()` then detects a disconnect/reconnect
        // WITHOUT any (slow, main-thread) Keychain read. syncNow is single-flight (`guard !syncing`), so the
        // creds loaded below stay authoritative for the whole pass.
        let gen = connGen
        let store = self.store
        func live() -> Bool { connected && gen == connGen }
        guard let creds = await Task.detached(operation: { store.load() }).value else { return }   // Keychain off-main
        guard live() else { return }                                   // disconnected during the creds load
        let startTime = Date()
        let resume = UserDefaults.standard.string(forKey: Self.cursorKey)
        // While draining a backlog the cursor carries the query. First-ever sync → full history. Steady
        // state → a window back from the last FULL sync (covers transcript delay + any downtime). The
        // seen-set, not a fragile per-call watermark, guarantees no double-import.
        let since: Date? = resume != nil ? nil : creds.lastSync.map { $0.addingTimeInterval(-Self.window) }
        do {
            let page = try await client.fetch(since: since, startCursor: resume)
            guard live() else { return }                               // disconnected mid-fetch (audit HIGH)

            var seen = Set(UserDefaults.standard.stringArray(forKey: Self.seenKey) ?? [])
            var seenOrder = UserDefaults.standard.stringArray(forKey: Self.seenKey) ?? []
            var imported = 0
            for m in page.meetings.sorted(by: { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }) {
                guard live() else { break }
                if m.lines.isEmpty { continue }                        // transcript not ready → re-scanned next poll
                if seen.contains(m.id) { continue }
                do {
                    let outcome = try await env.ingest.ingest(m.toParsedTranscript())
                    guard live() else { return }                       // disconnected mid-loop (audit HIGH)
                    seen.insert(m.id); seenOrder.append(m.id)
                    if !outcome.deduped {
                        env.generateTitleIntelligence(for: outcome.meetingID)
                        env.summarizeInBackground(outcome.meetingID)
                        env.classifyInBackground(outcome.meetingID)
                        imported += 1
                    }
                } catch {
                    continue   // one bad call can't abort the rest; it's re-scanned next poll within the window
                }
            }

            // Persist only after re-confirming we're still connected (audit HIGH — no resurrection on disconnect).
            guard live() else { return }
            if seenOrder.count > Self.seenCap { seenOrder = Array(seenOrder.suffix(Self.seenCap)) }
            UserDefaults.standard.set(seenOrder, forKey: Self.seenKey)
            if page.complete {
                UserDefaults.standard.removeObject(forKey: Self.cursorKey)
                // Forward-only watermark — the START of a fully-drained sync, never moving backward. Use the
                // creds captured at the top (apiKey is stable; lastSync only advances here, single-flight) and
                // write it back OFF-MAIN so the Keychain save never freezes the UI.
                let advanced = max(creds.lastSync ?? .distantPast, startTime)
                let key = creds.apiKey
                _ = await Task.detached { store.save(FathomCredentials(apiKey: key, lastSync: advanced)) }.value
            } else {
                UserDefaults.standard.set(page.nextCursor, forKey: Self.cursorKey)   // keep draining; don't advance
            }
            lastSyncCount += imported
            status = imported == 0
                ? (page.complete ? "Up to date." : "Importing more…")
                : "Imported \(imported) new call\(imported == 1 ? "" : "s")."
        } catch FathomError.unauthorized {
            status = "Fathom API key was rejected — reconnect in Settings."
        } catch {
            status = "Sync failed — will retry. (\(error.localizedDescription))"
        }
    }
}
