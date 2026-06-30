import Foundation
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
    private static let seenKey = "callbrain.fathomSeenIDs"
    private static let cursorKey = "callbrain.fathomResumeCursor"
    private static let seenCap = 6000
    /// Steady-state we re-scan a window back from the last FULL sync — wide enough to cover a transcript
    /// that wasn't ready yet AND any time the app was closed. The seen-id set (+ ingest content-dedupe) is
    /// the source of truth for "already imported", so re-scanning is free of duplicates; this window only
    /// bounds how far back we look.
    private static let window: TimeInterval = 3 * 86_400

    init(env: AppEnvironment) {
        self.env = env
        self.client = FathomClient(store: store)
        self.connected = !((store.load()?.apiKey).map { $0.isEmpty } ?? true)
        if connected {
            Task { [weak self] in await self?.syncNow() }
            startAutoSync()
        }
    }

    var isConfigured: Bool { connected }

    /// Save + validate the API key, then connect and pull the first batch.
    func connect(apiKey: String) async {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { status = "Paste your Fathom API key first."; return }
        // Require the Keychain write to actually succeed before claiming connected (audit MED).
        guard store.save(FathomCredentials(apiKey: key, lastSync: store.load()?.lastSync)),
              store.load()?.apiKey == key else {
            status = "Couldn't save the key to your Keychain — try again."; return
        }
        status = "Checking your Fathom key…"
        do {
            _ = try await client.fetch(since: nil, startCursor: nil, maxPages: 1, pageSize: 1)   // validates
            connected = true
            status = "Connected — importing your Fathom calls…"
            startAutoSync()
            await syncNow()
        } catch FathomError.unauthorized {
            store.clear(); connected = false
            status = "That API key was rejected. Generate one at fathom.video → Settings → Integrations → API."
        } catch {
            connected = true; startAutoSync()        // key saved; transient network error → auto-sync retries
            status = "Saved — couldn't reach Fathom just now; it'll retry automatically."
        }
    }

    func disconnect() {
        autoSyncTask?.cancel(); autoSyncTask = nil
        store.clear()
        UserDefaults.standard.removeObject(forKey: Self.seenKey)
        UserDefaults.standard.removeObject(forKey: Self.cursorKey)
        connected = false
        status = "Disconnected."
    }

    private func startAutoSync() {
        autoSyncTask?.cancel()
        autoSyncTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(900))   // every 15 min
                if Task.isCancelled { break }
                await self?.syncNow()
            }
        }
    }

    func syncNow() async {
        guard connected, !syncing, let creds = store.load() else { return }
        syncing = true; defer { syncing = false }
        let startTime = Date()
        let resume = UserDefaults.standard.string(forKey: Self.cursorKey)
        // While draining a backlog the cursor carries the query. First-ever sync → full history. Steady
        // state → a window back from the last FULL sync (covers transcript delay + any downtime). The
        // seen-set, not a fragile per-call watermark, guarantees no double-import.
        let since: Date? = resume != nil ? nil : creds.lastSync.map { $0.addingTimeInterval(-Self.window) }
        do {
            let page = try await client.fetch(since: since, startCursor: resume)
            guard connected, store.load() != nil else { return }       // disconnected mid-fetch (audit HIGH)

            var seen = Set(UserDefaults.standard.stringArray(forKey: Self.seenKey) ?? [])
            var seenOrder = UserDefaults.standard.stringArray(forKey: Self.seenKey) ?? []
            var imported = 0
            for m in page.meetings.sorted(by: { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }) {
                guard connected else { break }
                if m.lines.isEmpty { continue }                        // transcript not ready → re-scanned next poll
                if seen.contains(m.id) { continue }
                do {
                    let outcome = try await env.ingest.ingest(m.toParsedTranscript())
                    guard connected, store.load() != nil else { return }   // disconnected mid-loop (audit HIGH)
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
            guard connected, let cur = store.load() else { return }
            if seenOrder.count > Self.seenCap { seenOrder = Array(seenOrder.suffix(Self.seenCap)) }
            UserDefaults.standard.set(seenOrder, forKey: Self.seenKey)
            if page.complete {
                UserDefaults.standard.removeObject(forKey: Self.cursorKey)
                // Forward-only watermark — the START of a fully-drained sync, never moving backward.
                let advanced = max(cur.lastSync ?? .distantPast, startTime)
                store.save(FathomCredentials(apiKey: cur.apiKey, lastSync: advanced))
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
