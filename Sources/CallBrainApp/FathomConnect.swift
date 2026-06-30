import Foundation
import CallBrainCore

/// Auto-imports Fathom calls by polling the Fathom public API (api.fathom.ai) — connect once with a free
/// API key, then it pulls every new call in the background (transcript + attendees), runs it through the
/// same ingest/dedupe/title/summary/categorize pipeline, and keeps a watermark so each poll only fetches
/// what's new. No external infra, no per-call step.
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
    private static let seenCap = 6000
    /// Re-fetch this far back each poll so a call whose transcript wasn't ready last time still gets picked
    /// up once Fathom finishes processing it.
    private static let lookbackBuffer: TimeInterval = 2 * 86_400

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
        store.save(FathomCredentials(apiKey: key, lastSync: store.load()?.lastSync))
        status = "Checking your Fathom key…"
        do {
            _ = try await client.newMeetings(since: nil, maxPages: 1, pageSize: 1)   // validates the key
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
        guard connected, !syncing else { return }
        syncing = true; defer { syncing = false }
        let creds = store.load()
        let since = creds?.lastSync.map { $0.addingTimeInterval(-Self.lookbackBuffer) }
        do {
            let meetings = try await client.newMeetings(since: since)
            var seen = Set(UserDefaults.standard.stringArray(forKey: Self.seenKey) ?? [])
            var seenOrder = UserDefaults.standard.stringArray(forKey: Self.seenKey) ?? []
            var imported = 0
            var newest = creds?.lastSync
            // Oldest-first so ordering + the watermark advance sanely.
            for m in meetings.sorted(by: { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }) {
                guard connected else { break }
                if let c = m.createdAt, c > (newest ?? .distantPast) { newest = c }
                guard !m.lines.isEmpty else { continue }          // transcript not ready yet → retry next poll
                guard !seen.contains(m.id) else { continue }
                let outcome = try await env.ingest.ingest(m.toParsedTranscript())
                seen.insert(m.id); seenOrder.append(m.id)
                if !outcome.deduped {
                    env.generateTitleIntelligence(for: outcome.meetingID)
                    env.summarizeInBackground(outcome.meetingID)
                    env.classifyInBackground(outcome.meetingID)
                    imported += 1
                }
            }
            if seenOrder.count > Self.seenCap { seenOrder = Array(seenOrder.suffix(Self.seenCap)) }
            UserDefaults.standard.set(seenOrder, forKey: Self.seenKey)
            if let creds { store.save(FathomCredentials(apiKey: creds.apiKey, lastSync: newest)) }
            lastSyncCount += imported
            status = imported == 0 ? "Up to date." : "Imported \(imported) new call\(imported == 1 ? "" : "s")."
        } catch FathomError.unauthorized {
            status = "Fathom API key was rejected — reconnect in Settings."
        } catch {
            status = "Sync failed — will retry. (\(error.localizedDescription))"
        }
    }
}
