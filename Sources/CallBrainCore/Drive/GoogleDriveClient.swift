import Foundation

/// What we persist for a connected Google Drive (in the Keychain, via `DriveCredentialStore`).
public struct DriveCredentials: Codable, Sendable, Equatable {
    public var clientID: String
    public var clientSecret: String
    public var refreshToken: String
    public var accessToken: String?
    public var expiry: Date?
    public init(clientID: String, clientSecret: String, refreshToken: String,
                accessToken: String? = nil, expiry: Date? = nil) {
        self.clientID = clientID; self.clientSecret = clientSecret; self.refreshToken = refreshToken
        self.accessToken = accessToken; self.expiry = expiry
    }
}

/// Where Drive credentials live (Keychain in the app; a memory stub in tests). `save` returns whether the
/// write actually succeeded so security-critical callers can refuse to report "connected" on a failed write.
public protocol DriveCredentialStore: Sendable {
    func load() -> DriveCredentials?
    @discardableResult func save(_ c: DriveCredentials) -> Bool
    func clear()
}

/// Networked Google Drive v3 client. Holds the connection via a `DriveCredentialStore`, transparently
/// refreshes the access token (and retries a 401 once), and downloads/export files. Uses the pure
/// builders in `GoogleOAuth`/`DriveAPI`. The actual loopback OAuth handshake is driven app-side, which
/// then calls `connect(code:…)` here to mint + store the refresh token.
public actor GoogleDriveClient {
    private let store: any DriveCredentialStore
    private let session: URLSession
    private let now: @Sendable () -> Date
    /// Bumped on connect/disconnect; a refresh that started before a disconnect won't write its new token
    /// back (which would "resurrect" a disconnected account — SME MED actor/main race).
    private var epoch = 0

    public init(store: any DriveCredentialStore, session: URLSession = .shared,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store; self.session = session; self.now = now
    }

    public func isConnected() -> Bool { !(store.load()?.refreshToken ?? "").isEmpty }

    /// Clear tokens (serialized on the actor with any in-flight refresh), optionally re-saving the OAuth
    /// client config so reconnecting is one tap.
    public func disconnect(preservingConfig cfg: DriveCredentials? = nil) {
        epoch += 1
        store.clear()
        if let cfg { store.save(DriveCredentials(clientID: cfg.clientID, clientSecret: cfg.clientSecret, refreshToken: "")) }
    }

    /// Finish the OAuth handshake: exchange the auth code for tokens and persist the refresh token.
    public func connect(code: String, codeVerifier: String, redirectURI: String,
                        clientID: String, clientSecret: String) async throws {
        let startEpoch = epoch
        let body = GoogleOAuth.tokenExchangeBody(code: code, clientID: clientID, clientSecret: clientSecret,
                                                 redirectURI: redirectURI, codeVerifier: codeVerifier)
        let data = try await postForm(GoogleOAuth.tokenEndpoint, body: body)
        let tr = try GoogleOAuth.parseTokenResponse(data)
        guard let rt = tr.refresh_token, !rt.isEmpty else {
            throw DriveError.oauth("Google didn't return a refresh token — revoke the app's access and reconnect.")
        }
        // If the user disconnected while the token exchange was in flight, don't resurrect the connection.
        guard epoch == startEpoch else { throw DriveError.notConnected }
        epoch += 1   // new connection generation (invalidates any prior in-flight refresh)
        let saved = store.save(DriveCredentials(clientID: clientID, clientSecret: clientSecret, refreshToken: rt,
                                                accessToken: tr.access_token,
                                                expiry: now().addingTimeInterval(TimeInterval(tr.expires_in ?? 3600))))
        // Surface a Keychain write that didn't stick, instead of reporting "Connected" falsely (SME MED).
        guard saved, store.load()?.refreshToken == rt else {
            throw DriveError.badResponse("couldn't save Google credentials to the Keychain")
        }
    }

    /// All non-trashed files under a folder (paginated, bounded). Guards against a malformed response that
    /// returns the same `nextPageToken` forever (SME: infinite loop).
    public func listFiles(folderID: String?) async throws -> [DriveAPI.DriveFile] {
        var out: [DriveAPI.DriveFile] = []; var page: String?
        var pages = 0; var seenTokens = Set<String>()
        repeat {
            guard let url = DriveAPI.listURL(folderID: folderID, pageToken: page) else { break }
            let list = try decode(DriveAPI.FileList.self, try await authedGET(url))
            out += list.files
            page = list.nextPageToken
            pages += 1
            if let p = page, !seenTokens.insert(p).inserted { break }   // repeated token → stop
        } while (page != nil) && out.count < 6000 && pages < 60
        return out
    }

    public func findFolder(named name: String) async throws -> DriveAPI.DriveFile? {
        guard let url = DriveAPI.folderSearchURL(name: name) else { return nil }
        // Stable pick when Drive has duplicate folder names: lowest id (SME: arbitrary .first).
        return try decode(DriveAPI.FileList.self, try await authedGET(url)).files.sorted { $0.id < $1.id }.first
    }

    /// All non-trashed folders (for the folder picker).
    public func listFolders() async throws -> [DriveAPI.DriveFile] {
        guard let url = DriveAPI.foldersListURL() else { return [] }
        return try decode(DriveAPI.FileList.self, try await authedGET(url)).files
    }

    /// STREAM a Drive file straight to `dest` (never buffering the whole body in RAM — Meet recordings can
    /// be multi-GB; SME HIGH). Refuses any non-Google host so the Bearer token is never attached to an
    /// arbitrary URL (SME HIGH: token exfiltration). Refreshes + retries once on 401.
    public func downloadToFile(_ url: URL, dest: URL) async throws {
        try assertGoogle(url)
        let fm = FileManager.default
        var token = try await validAccessToken()
        var (tmp, resp) = try await session.download(for: authedRequest(url, token: token))
        if (resp as? HTTPURLResponse)?.statusCode == 401 {
            try? fm.removeItem(at: tmp)                              // don't leak the unauthorized partial
            token = try await validAccessToken(forceRefresh: true)
            (tmp, resp) = try await session.download(for: authedRequest(url, token: token))
        }
        try Self.check(resp, Data())
        // Replace the destination atomically — never delete the previous file before the new one is in place.
        if fm.fileExists(atPath: dest.path) {
            _ = try fm.replaceItemAt(dest, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: dest)
        }
    }

    private func assertGoogle(_ url: URL) throws {
        guard url.scheme == "https", let host = url.host,
              host == "www.googleapis.com" || host.hasSuffix(".googleapis.com") else {
            throw DriveError.badResponse("refusing to attach Drive credentials to a non-Google URL")
        }
    }
    private func authedRequest(_ url: URL, token: String) -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 600
        return req
    }

    // MARK: - token lifecycle

    private func validAccessToken(forceRefresh: Bool = false) async throws -> String {
        guard var creds = store.load() else { throw DriveError.notConnected }
        if !forceRefresh, let tok = creds.accessToken, let exp = creds.expiry,
           exp.timeIntervalSince(now()) > 60 { return tok }
        let startEpoch = epoch
        let body = GoogleOAuth.tokenRefreshBody(refreshToken: creds.refreshToken,
                                                clientID: creds.clientID, clientSecret: creds.clientSecret)
        let tr = try GoogleOAuth.parseTokenResponse(try await postForm(GoogleOAuth.tokenEndpoint, body: body))
        guard let token = tr.access_token else { throw DriveError.badResponse("no access token on refresh") }
        // If a disconnect/reconnect happened while we were on the network, don't write this token back.
        guard epoch == startEpoch else { throw DriveError.notConnected }
        creds.accessToken = token
        creds.expiry = now().addingTimeInterval(TimeInterval(tr.expires_in ?? 3600))
        if let rt = tr.refresh_token, !rt.isEmpty { creds.refreshToken = rt }
        store.save(creds)
        return token
    }

    private func authedGET(_ url: URL) async throws -> Data {
        var token = try await validAccessToken()
        var (data, resp) = try await get(url, token: token)
        if (resp as? HTTPURLResponse)?.statusCode == 401 {          // token rejected → refresh once + retry
            token = try await validAccessToken(forceRefresh: true)
            (data, resp) = try await get(url, token: token)
        }
        try Self.check(resp, data)
        return data
    }

    private func get(_ url: URL, token: String) async throws -> (Data, URLResponse) {
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 60
        return try await session.data(for: req)
    }

    private func postForm(_ endpoint: String, body: String) async throws -> Data {
        guard let url = URL(string: endpoint) else { throw DriveError.badResponse("bad endpoint") }
        var req = URLRequest(url: url); req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(body.utf8); req.timeoutInterval = 60
        let (data, resp) = try await session.data(for: req)
        try Self.check(resp, data, allowJSONError: true)            // token endpoint returns JSON errors
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw DriveError.badResponse("decode: \(error)") }
    }

    static func check(_ resp: URLResponse, _ data: Data, allowJSONError: Bool = false) throws {
        guard let http = resp as? HTTPURLResponse else { return }
        if allowJSONError && http.statusCode >= 400 { return }      // parsed by parseTokenResponse
        guard (200..<300).contains(http.statusCode) else {
            throw DriveError.http(status: http.statusCode, body: String(decoding: data.prefix(400), as: UTF8.self))
        }
    }
}
