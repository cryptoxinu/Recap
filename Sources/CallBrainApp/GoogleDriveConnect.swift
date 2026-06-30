import SwiftUI
import Network
import AppKit
import CallBrainCore

// MARK: - Loopback OAuth redirect server

/// One-shot loopback HTTP server for the OAuth redirect. Binds **127.0.0.1** on an OS-assigned port,
/// captures the single `GET /?code=…&state=…` the browser is redirected to, replies with a small
/// "you can close this" page, then stops. Loopback-only + a random `state` (checked by the caller) keep
/// the handshake safe.
final class LoopbackServer: @unchecked Sendable {
    private var listener: NWListener?
    private let lock = NSLock()
    private var finished = false
    private var cont: CheckedContinuation<(code: String, state: String), Error>?
    private var buffered: Result<(code: String, state: String), Error>?
    private var startCont: CheckedContinuation<UInt16, Error>?
    private var startFired = false

    /// Start listening on 127.0.0.1; returns the assigned port once ready.
    func start() async throws -> UInt16 {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: 0)!)
        let listener = try NWListener(using: params)
        self.listener = listener
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, Error>) in
            lock.lock(); startCont = cont; lock.unlock()
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: self?.resumeStart(.success(listener.port?.rawValue))
                case .failed(let e): self?.resumeStart(.failure(e))
                case .cancelled: self?.resumeStart(.failure(DriveError.oauth("cancelled")))
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
            listener.start(queue: .global())
        }
    }

    /// Resume the start() continuation at most once — so `cancel()` before `.ready` can't leak it (SME HIGH).
    private func resumeStart(_ r: Result<UInt16?, Error>) {
        lock.lock()
        guard !startFired, let c = startCont else { lock.unlock(); return }
        startFired = true; startCont = nil
        lock.unlock()
        switch r {
        case .success(let p?): c.resume(returning: p)
        case .success(nil): c.resume(throwing: DriveError.badResponse("loopback: no port"))
        case .failure(let e): c.resume(throwing: e)
        }
    }

    /// Await the captured auth code (resolves when the browser redirect arrives, or immediately if it
    /// already did).
    func waitForCode() async throws -> (code: String, state: String) {
        try await withCheckedThrowingContinuation { c in
            lock.lock()
            if let b = buffered { lock.unlock(); c.resume(with: b); return }
            cont = c
            lock.unlock()
        }
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .global())
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
            guard let self else { conn.cancel(); return }
            let req = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let firstLine = req.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? req
            let target = firstLine.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            let query = target.firstIndex(of: "?").map { String(target[target.index(after: $0)...]) } ?? ""
            let parsed = GoogleOAuth.parseRedirect(query: query)
            let html = "<html><body style=\"font-family:-apple-system;padding:3rem;text-align:center;color:#222\">"
                + "<h2>CallBrain is connected to Google Drive ✅</h2><p>You can close this tab and return to the app.</p></body></html>"
            let resp = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
            conn.send(content: Data(resp.utf8), completion: .contentProcessed { _ in conn.cancel() })
            self.finish(parsed)
        }
    }

    private func finish(_ parsed: (code: String?, state: String?, error: String?)) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let c = cont; cont = nil
        let result: Result<(code: String, state: String), Error>
        if let err = parsed.error { result = .failure(DriveError.oauth(err)) }
        else if let code = parsed.code, let state = parsed.state { result = .success((code, state)) }
        else { result = .failure(DriveError.oauth("no authorization code in redirect")) }
        if c == nil { buffered = result }
        lock.unlock()
        listener?.cancel()
        c?.resume(with: result)
    }

    func cancel() {
        resumeStart(.failure(DriveError.oauth("cancelled")))   // don't leak a pending start() (SME HIGH)
        finish((nil, nil, "cancelled"))
    }
}

// MARK: - Drive connect / sync coordinator

@MainActor
@Observable
final class GoogleDriveConnect {
    private let env: AppEnvironment
    private let store = KeychainDriveCredentialStore()
    private let client: GoogleDriveClient
    private(set) var connected: Bool
    private(set) var status: String = ""
    private(set) var syncing = false
    private(set) var lastSyncCount = 0
    private(set) var availableFolders: [DriveAPI.DriveFile] = []
    var folderID: String? { didSet { UserDefaults.standard.set(folderID, forKey: Self.folderIDKey) } }
    var folderName: String? { didSet { UserDefaults.standard.set(folderName, forKey: Self.folderNameKey) } }
    /// Also import files shared WITH you (Gemini notes / recordings a meeting host shared — they never land
    /// in your own folders). On by default. Founder ask 2026-06-30.
    var includeShared: Bool {
        didSet { UserDefaults.standard.set(includeShared, forKey: Self.includeSharedKey) }
    }
    @ObservationIgnored private var autoSyncTask: Task<Void, Never>?
    /// Bumped on disconnect so an in-flight `syncNow` aborts promptly after its next await (instead of
    /// finishing the whole listing/download pass against a now-disconnected account).
    @ObservationIgnored private var syncGeneration = 0

    /// Cached "an OAuth client (id+secret) is stored" flag — so `isConfigured` never does a (slow,
    /// main-thread) Keychain read during a SwiftUI render. Reconciled off-main in init.
    private(set) var hasClient: Bool

    static let folderIDKey = "callbrain.driveFolderID"
    static let folderNameKey = "callbrain.driveFolderName"
    static let includeSharedKey = "callbrain.driveIncludeShared"
    static let connectedKey = "callbrain.driveConnected"
    static let configuredKey = "callbrain.driveConfigured"
    static let syncedKey = "callbrain.driveSyncedKeys"
    static let syncedCap = 8000

    init(env: AppEnvironment) {
        self.env = env
        self.client = GoogleDriveClient(store: store)
        // Read the cached flags (instant) instead of the Keychain — an unsigned-binary Keychain read costs
        // ~6s and that was beachballing the launch. The Keychain is the source of truth; these mirrors are
        // reconciled off-main right after launch (audit: launch-latency).
        self.connected = UserDefaults.standard.bool(forKey: Self.connectedKey)
        self.hasClient = UserDefaults.standard.bool(forKey: Self.configuredKey)
        self.folderID = UserDefaults.standard.string(forKey: Self.folderIDKey)
        self.folderName = UserDefaults.standard.string(forKey: Self.folderNameKey)
        self.includeShared = UserDefaults.standard.object(forKey: Self.includeSharedKey) as? Bool ?? true
        // Catch-up sync on launch + keep it fresh — for a folder sync OR a shared-with-me-only setup.
        if connected, (!((folderID ?? "").isEmpty) || includeShared) {
            Task { [weak self] in await self?.syncNow() }
            startAutoSync()
        }
        // Existing users connected/configured BEFORE these flags existed have Keychain state but no cached
        // flags yet. Read the real Keychain OFF-MAIN (slow on an unsigned binary) and self-heal — and if it
        // flips us connected, kick the catch-up sync the fast path skipped. Keeps launch instant + honest.
        let store = self.store
        let gen = syncGeneration
        Task.detached { [weak self] in
            let cfg = store.load()
            let real = !((cfg?.refreshToken).map { $0.isEmpty } ?? true)
            let client = !((cfg?.clientID).map { $0.isEmpty } ?? true)
            await self?.reconcileConnected(real, hasClient: client, gen: gen)
        }
    }

    private func setConnected(_ v: Bool) {
        syncGeneration &+= 1          // any transition invalidates in-flight syncs + stale reconciles
        connected = v
        UserDefaults.standard.set(v, forKey: Self.connectedKey)
    }

    private func setHasClient(_ v: Bool) {
        hasClient = v
        UserDefaults.standard.set(v, forKey: Self.configuredKey)
    }

    /// Reconcile the cached flags against the real Keychain (called off-main → hops back here on main).
    /// `gen` is the sync generation captured before the off-main read; if the user connected or
    /// disconnected meanwhile it will have changed, so we drop the now-stale snapshot (audit HIGH: race).
    private func reconcileConnected(_ real: Bool, hasClient client: Bool, gen: Int) {
        if client != hasClient { setHasClient(client) }
        guard gen == syncGeneration, real != connected else { return }
        setConnected(real)
        if real, (!((folderID ?? "").isEmpty) || includeShared) {
            startAutoSync()
            Task { [weak self] in await self?.syncNow() }
        } else if !real {
            autoSyncTask?.cancel(); autoSyncTask = nil    // drop a timer started from a stale cached `true`
        }
    }

    /// Background sync every 15 min while connected (so new Drive notes flow in without a manual tap).
    private func startAutoSync() {
        autoSyncTask?.cancel()
        autoSyncTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(900))
                if Task.isCancelled { break }
                await self?.syncNow()
            }
        }
    }

    /// Load the user's folders for the picker.
    func loadFolders() async {
        guard connected else { return }
        availableFolders = (try? await client.listFolders()) ?? []
    }

    /// Select a Drive folder to sync, then pull it.
    func selectFolder(_ f: DriveAPI.DriveFile) {
        folderID = f.id; folderName = f.name
        Task { [weak self] in await self?.syncNow() }
    }

    var isConfigured: Bool { hasClient }     // cached — never a main-thread Keychain read during render

    /// Store the founder's Desktop-app OAuth client (id + secret). Not yet connected until `connect()`.
    func configure(clientID: String, clientSecret: String) async {
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        let store = self.store
        _ = await Task.detached { store.save(DriveCredentials(clientID: id, clientSecret: secret, refreshToken: "")) }.value
        setHasClient(!id.isEmpty)
        status = "Client saved — now connect."
    }

    /// Run the loopback OAuth handshake and persist the refresh token.
    func connect() async {
        let store = self.store
        guard let cfg = await Task.detached(operation: { store.load() }).value, !cfg.clientID.isEmpty else {
            status = "Enter your Google OAuth client first."; return
        }
        let server = LoopbackServer()
        do {
            let verifier = GoogleOAuth.makeCodeVerifier()
            let challenge = GoogleOAuth.codeChallenge(for: verifier)
            let state = GoogleOAuth.makeState()
            let port = try await server.start()
            let redirect = "http://127.0.0.1:\(port)"
            guard let authURL = GoogleOAuth.authorizationURL(clientID: cfg.clientID, redirectURI: redirect,
                                                             codeChallenge: challenge, state: state) else {
                status = "Couldn't build the sign-in URL."; server.cancel(); return
            }
            guard NSWorkspace.shared.open(authURL) else {
                status = "Couldn't open your browser to sign in."; server.cancel(); return
            }
            status = "Waiting for Google sign-in in your browser…"
            // Don't hang if the user abandons the browser flow. The wait task is wrapped in a cancellation
            // handler that tears down the loopback (→ resumes waitForCode), so when the timeout task throws
            // and the group is cancelled, the wait task actually completes and the group can drain (SME HIGH).
            let (code, gotState) = try await withThrowingTaskGroup(of: (code: String, state: String).self) { group in
                group.addTask {
                    try await withTaskCancellationHandler { try await server.waitForCode() }
                    onCancel: { server.cancel() }
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(300))
                    server.cancel()                                 // resume the wait task before throwing
                    throw DriveError.oauth("timed out waiting for Google sign-in")
                }
                defer { group.cancelAll() }
                guard let first = try await group.next() else { throw DriveError.oauth("sign-in cancelled") }
                return first
            }
            guard gotState == state else { status = "Sign-in failed (state mismatch)."; server.cancel(); return }
            try await client.connect(code: code, codeVerifier: verifier, redirectURI: redirect,
                                     clientID: cfg.clientID, clientSecret: cfg.clientSecret)
            setConnected(true)
            status = "Connected to Google Drive."
            await detectMeetRecordings()
            startAutoSync()
        } catch {
            server.cancel()
            status = "Connect failed: \(Self.message(error))"
        }
    }

    func disconnect() {
        // Clear tokens via the shared store (same item the actor uses), but keep the OAuth client config so
        // reconnecting is one tap. Also clear the selected folder + per-account dedupe set so reconnecting
        // to a DIFFERENT Google account doesn't reuse a stale folder id or skip that account's files (SME).
        autoSyncTask?.cancel(); autoSyncTask = nil
        // Clear tokens THROUGH the actor so it's serialized with any in-flight refresh (no token
        // resurrection). Detached so the slow Keychain read+clear runs OFF-MAIN (it would freeze the UI on
        // an unsigned binary otherwise). `setConnected(false)` bumps `syncGeneration`, so any in-flight
        // syncNow aborts at its next `live()` check without needing a Keychain read.
        let store = self.store, client = self.client
        Task.detached { await client.disconnect(preservingConfig: store.load()) }
        folderID = nil; folderName = nil; availableFolders = []
        UserDefaults.standard.removeObject(forKey: Self.syncedKey)
        setConnected(false)
        status = "Disconnected."
    }

    /// Locate the Drive "Meet Recordings" folder (where Google Meet's Gemini notes land) and select it.
    func detectMeetRecordings() async {
        do {
            if let folder = try await client.findFolder(named: "Meet Recordings") {
                folderID = folder.id; folderName = folder.name
                status = "Watching “\(folder.name)”. Syncing…"
                await syncNow()
            } else {
                await loadFolders()
                status = "Connected — choose a folder to sync."
            }
        } catch { status = "Connected, but folder lookup failed: \(Self.message(error))" }
    }

    /// Pull new files from the selected Drive folder into the import queue.
    func syncNow() async {
        guard connected, !syncing else { return }
        let hasFolder = !((folderID ?? "").isEmpty)
        // Sync the chosen folder AND/OR files shared with you. Never the whole Drive (SME HIGH).
        guard hasFolder || includeShared else { status = "Choose a Drive folder to sync first."; return }
        syncing = true; defer { syncing = false }
        let gen = syncGeneration
        // Live only while still connected AND this exact sync wasn't superseded by a disconnect/reconnect.
        func live() -> Bool { connected && gen == syncGeneration }
        do {
            var files: [DriveAPI.DriveFile] = []
            if hasFolder, let fid = folderID { files += try await client.listFiles(folderID: fid) }
            guard live() else { return }                                          // disconnected during listing
            // Shared files are post-filtered to meeting artifacts so the user's whole shared corpus isn't
            // imported as fake meetings (audit HIGH).
            if includeShared { files += try await client.listSharedWithMe().filter(DriveAPI.isLikelyMeeting) }
            guard live() else { return }
            var seenIDs = Set<String>(); files = files.filter { seenIDs.insert($0.id).inserted }   // de-dup overlap
            let importable = IngestEngine.readableExtensions.union(ImportCoordinator.mediaExtensions)
            let seen = Set(UserDefaults.standard.stringArray(forKey: Self.syncedKey) ?? [])
            var seenOrder = UserDefaults.standard.stringArray(forKey: Self.syncedKey) ?? []
            let cacheDir = env.dataRoot.appendingPathComponent("drive-import", isDirectory: true)
            try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

            var pending: [(key: String, url: URL)] = []; var failed = 0
            for f in files {
                guard live() else { break }   // user disconnected/reconnected mid-sync → stop downloading (audit MED)
                let key = "\(f.id)@\(f.modifiedTime ?? "")"
                guard !seen.contains(key), let plan = DriveAPI.fetchPlan(for: f, importable: importable) else { continue }
                do {
                    // Unique, collision-proof filename (file id), streamed straight to disk (no multi-GB
                    // buffering in RAM — SME HIGH), so two same-named files can't clobber each other.
                    let safeBase = (f.name as NSString).deletingPathExtension
                        .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
                    let dest = cacheDir.appendingPathComponent("\(safeBase)-\(f.id).\(plan.ext)")
                    try await client.downloadToFile(plan.url, dest: dest)
                    pending.append((key: key, url: dest))
                } catch { failed += 1 }   // skip a single bad file; keep going, but count it
            }
            var imported = 0
            if live(), !pending.isEmpty {
                // Mark synced ONLY the files that actually persisted an import job — a file whose job failed
                // must NOT be recorded as synced (it would never retry; audit HIGH).
                let queued = Set(env.importCoordinator.enqueueFilesReturningQueued(pending.map(\.url)))
                for p in pending where queued.contains(p.url) { seenOrder.append(p.key) }
                imported = queued.count
                lastSyncCount += imported
                if seenOrder.count > Self.syncedCap { seenOrder = Array(seenOrder.suffix(Self.syncedCap)) }
                UserDefaults.standard.set(seenOrder, forKey: Self.syncedKey)
            }
            status = imported == 0 && failed == 0 ? "Up to date."
                : "Imported \(imported) new file\(imported == 1 ? "" : "s")" + (failed > 0 ? " · \(failed) failed" : "") + "."
        } catch {
            status = "Sync failed: \(Self.message(error))"
        }
    }

    static func message(_ e: Error) -> String {
        if let d = e as? DriveError {
            switch d {
            case .notConfigured: return "no OAuth client set"
            case .notConnected: return "not connected"
            case .oauth(let m): return m
            case .http(let s, _): return "Google returned HTTP \(s)"
            case .badResponse(let m): return m
            }
        }
        return e.localizedDescription
    }
}

// MARK: - Zero-OAuth folder auto-detect (the non-coder path)

/// Finds the Google Drive desktop app's local "Meet Recordings" folder, so a non-developer can one-click
/// auto-import without any OAuth setup (the Drive desktop app already syncs Gemini notes to disk).
enum GoogleDriveDetect {
    static func meetRecordingsFolder() -> URL? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var roots: [URL] = [home.appendingPathComponent("Google Drive")]
        // Modern macOS File-Provider mount: ~/Library/CloudStorage/GoogleDrive-<email>/My Drive
        let cloud = home.appendingPathComponent("Library/CloudStorage")
        if let entries = try? fm.contentsOfDirectory(at: cloud, includingPropertiesForKeys: nil) {
            // Deterministic order so a multi-account machine resolves the same folder every time (SME MED).
            for e in entries.filter({ $0.lastPathComponent.hasPrefix("GoogleDrive-") })
                .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                roots.append(e.appendingPathComponent("My Drive"))
                roots.append(e)
            }
        }
        for r in roots {
            let candidate = r.appendingPathComponent("Meet Recordings")
            guard let vals = try? candidate.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  vals.isDirectory == true, vals.isSymbolicLink != true else { continue }   // reject symlinks
            return candidate
        }
        return nil
    }
}
