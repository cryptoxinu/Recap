import Testing
import Foundation
@testable import CallBrainCore

@Suite("Google Drive — OAuth + API builders")
struct DriveOAuthTests {

    @Test("PKCE: challenge is deterministic, base64url, and matches a known SHA256 vector")
    func pkce() {
        // RFC 7636 Appendix B reference vector.
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        #expect(GoogleOAuth.codeChallenge(for: verifier) == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        // base64url: no '+', '/', or '=' padding
        let v = GoogleOAuth.makeCodeVerifier()
        #expect(v.count >= 43 && !v.contains("+") && !v.contains("/") && !v.contains("="))
    }

    @Test("authorizationURL carries PKCE + offline + the loopback redirect")
    func authURL() throws {
        let url = try #require(GoogleOAuth.authorizationURL(
            clientID: "cid.apps.googleusercontent.com", redirectURI: "http://127.0.0.1:5051",
            codeChallenge: "CHAL", state: "STATE"))
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func val(_ n: String) -> String? { q.first { $0.name == n }?.value }
        #expect(url.absoluteString.hasPrefix(GoogleOAuth.authEndpoint))
        #expect(val("client_id") == "cid.apps.googleusercontent.com")
        #expect(val("redirect_uri") == "http://127.0.0.1:5051")
        #expect(val("code_challenge") == "CHAL")
        #expect(val("code_challenge_method") == "S256")
        #expect(val("access_type") == "offline")
        #expect(val("response_type") == "code")
        #expect(val("scope") == GoogleOAuth.driveReadonlyScope)
    }

    @Test("token bodies are form-encoded with the right grant types")
    func tokenBodies() {
        let ex = GoogleOAuth.tokenExchangeBody(code: "abc", clientID: "cid", clientSecret: "sec",
                                               redirectURI: "http://127.0.0.1:1", codeVerifier: "ver")
        #expect(ex.contains("grant_type=authorization_code"))
        #expect(ex.contains("code=abc") && ex.contains("code_verifier=ver") && ex.contains("client_secret=sec"))
        let rf = GoogleOAuth.tokenRefreshBody(refreshToken: "rt", clientID: "cid", clientSecret: "sec")
        #expect(rf.contains("grant_type=refresh_token") && rf.contains("refresh_token=rt"))
    }

    @Test("parseRedirect pulls code/state and surfaces errors")
    func redirect() {
        let ok = GoogleOAuth.parseRedirect(query: "code=4/abc&state=xyz&scope=drive")
        #expect(ok.code == "4/abc" && ok.state == "xyz" && ok.error == nil)
        let denied = GoogleOAuth.parseRedirect(query: "error=access_denied&state=xyz")
        #expect(denied.error == "access_denied" && denied.code == nil)
    }

    @Test("parseTokenResponse throws on an error envelope, parses success")
    func tokenParse() throws {
        let bad = #"{"error":"invalid_grant","error_description":"Bad Request"}"#.data(using: .utf8)!
        #expect(throws: DriveError.self) { _ = try GoogleOAuth.parseTokenResponse(bad) }
        let good = #"{"access_token":"AT","refresh_token":"RT","expires_in":3600,"token_type":"Bearer"}"#.data(using: .utf8)!
        let r = try GoogleOAuth.parseTokenResponse(good)
        #expect(r.access_token == "AT" && r.refresh_token == "RT" && r.expires_in == 3600)
    }

    @Test("Drive v3 URL builders")
    func driveURLs() throws {
        let list = try #require(DriveAPI.listURL(folderID: "FID", pageToken: nil))
        let lq = URLComponents(url: list, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value
        #expect(lq == "'FID' in parents and trashed = false")
        #expect(list.absoluteString.contains("/drive/v3/files"))

        let search = try #require(DriveAPI.folderSearchURL(name: "Meet Recordings"))
        let sq = URLComponents(url: search, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value
        #expect(sq?.contains("name = 'Meet Recordings'") == true)
        #expect(sq?.contains("application/vnd.google-apps.folder") == true)

        #expect(DriveAPI.downloadURL(fileID: "X")?.absoluteString.contains("files/X?alt=media") == true)
        let export = try #require(DriveAPI.exportURL(fileID: "X", mime: DriveAPI.docxMime))
        #expect(export.absoluteString.contains("files/X/export"))
        #expect(export.absoluteString.contains("wordprocessingml"))
    }

    @Test("q-injection: a single quote in a folder id is escaped")
    func quoteEscape() {
        let url = DriveAPI.listURL(folderID: "a'b", pageToken: nil)
        let q = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value }
        #expect(q == "'a\\'b' in parents and trashed = false")
    }

    @Test("q escaping handles backslash BEFORE quote")
    func backslashEscape() {
        #expect(DriveAPI.esc(#"a\b'c"#) == #"a\\b\'c"#)   // \ → \\, then ' → \'
    }

    @Test("foldersListURL queries folders only, name-ordered")
    func foldersURL() throws {
        let u = try #require(DriveAPI.foldersListURL())
        let comps = URLComponents(url: u, resolvingAgainstBaseURL: false)
        let q = comps?.queryItems?.first { $0.name == "q" }?.value
        #expect(q?.contains("application/vnd.google-apps.folder") == true && q?.contains("trashed = false") == true)
        #expect(comps?.queryItems?.first { $0.name == "orderBy" }?.value == "name")
    }

    @Test("fetchPlan maps mime → how-to-fetch + local extension")
    func fetchPlan() {
        let importable: Set<String> = ["docx", "txt", "md", "vtt", "srt", "mp4", "m4a"]
        func plan(_ mime: String, _ name: String) -> (url: URL, ext: String)? {
            DriveAPI.fetchPlan(for: .init(id: "1", name: name, mimeType: mime), importable: importable)
        }
        #expect(plan("application/vnd.google-apps.document", "Sync").map { $0.ext } == "docx")       // Gemini notes
        #expect(plan(DriveAPI.docxMime, "Notes.docx")?.ext == "docx")
        #expect(plan("text/plain", "t.txt")?.ext == "txt")
        #expect(plan("application/vnd.google-apps.folder", "Folder") == nil)                          // skip folders
        #expect(plan("application/octet-stream", "call.vtt")?.ext == "vtt")                           // by-name fallback
        #expect(plan("image/png", "shot.png") == nil)                                                 // not importable
    }

    @Test("shared-with-me query is narrowed to recordings + docs, never the whole shared corpus")
    func sharedQueryNarrowed() throws {
        let u = try #require(DriveAPI.sharedWithMeListURL(pageToken: nil))
        let q = try #require(URLComponents(url: u, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "q" }?.value)
        #expect(q.contains("sharedWithMe = true"))
        #expect(q.contains("video/") && q.contains("audio/"))
        #expect(q.contains("application/vnd.google-apps.document"))
    }

    @Test("isLikelyMeeting keeps recordings + meeting docs, rejects an arbitrary shared doc")
    func isLikelyMeeting() {
        func f(_ name: String, _ mime: String) -> DriveAPI.DriveFile { .init(id: "1", name: name, mimeType: mime) }
        #expect(DriveAPI.isLikelyMeeting(f("Standup recording.mp4", "video/mp4")))                    // any recording
        #expect(DriveAPI.isLikelyMeeting(f("Q3 planning – Notes by Gemini", DriveAPI.googleDocMime)))  // Gemini notes
        #expect(DriveAPI.isLikelyMeeting(f("Sales call transcript", "text/plain")))
        #expect(!DriveAPI.isLikelyMeeting(f("Q3 Budget", DriveAPI.googleDocMime)))                     // random shared doc
        #expect(!DriveAPI.isLikelyMeeting(f("Roadmap", DriveAPI.docxMime)))
    }
}

/// URLSession moves a POST `httpBody` into `httpBodyStream`; read whichever is set.
@Sendable func readBody(_ req: URLRequest) -> String {
    if let b = req.httpBody { return String(data: b, encoding: .utf8) ?? "" }
    guard let stream = req.httpBodyStream else { return "" }
    stream.open(); defer { stream.close() }
    var data = Data(); let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096); defer { buf.deallocate() }
    while stream.hasBytesAvailable { let n = stream.read(buf, maxLength: 4096); if n <= 0 { break }; data.append(buf, count: n) }
    return String(data: data, encoding: .utf8) ?? ""
}

/// Stubs URLSession so the token-lifecycle logic (connect → store, refresh-when-expired, 401-retry) is
/// tested without hitting Google.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, data) = Self.handler?(request) ?? (500, Data())
        let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("Google Drive — client token lifecycle")
struct DriveClientTests {
    func makeClient(now: @escaping @Sendable () -> Date, store: InMemoryDriveCredentialStore) -> GoogleDriveClient {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        return GoogleDriveClient(store: store, session: URLSession(configuration: cfg), now: now)
    }

    @Test("connect stores the refresh token; expired access token triggers a refresh")
    func connectAndRefresh() async throws {
        let store = InMemoryDriveCredentialStore()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let clock = ClockBox(t0)
        let client = makeClient(now: { clock.value }, store: store)

        StubURLProtocol.handler = { req in
            let url = req.url?.absoluteString ?? ""
            if url.contains("oauth2.googleapis.com/token") {
                let body = readBody(req)
                if body.contains("authorization_code") {
                    return (200, #"{"access_token":"AT1","refresh_token":"RT","expires_in":3600}"#.data(using: .utf8)!)
                }
                return (200, #"{"access_token":"AT2","expires_in":3600}"#.data(using: .utf8)!)   // refresh
            }
            return (200, #"{"files":[]}"#.data(using: .utf8)!)   // a Drive list call
        }

        try await client.connect(code: "c", codeVerifier: "v", redirectURI: "http://127.0.0.1:1",
                                 clientID: "cid", clientSecret: "sec")
        #expect(store.load()?.refreshToken == "RT")
        #expect(store.load()?.accessToken == "AT1")
        #expect(await client.isConnected())

        // Advance past expiry → the next API call must refresh (AT1 → AT2).
        clock.advance(4000)
        _ = try await client.listFiles(folderID: "F")
        #expect(store.load()?.accessToken == "AT2")
    }
}

/// Mutable clock for the lifecycle test (Date() is non-deterministic).
final class ClockBox: @unchecked Sendable {
    private let lock = NSLock(); private var t: Date
    init(_ t: Date) { self.t = t }
    var value: Date { lock.lock(); defer { lock.unlock() }; return t }
    func advance(_ s: TimeInterval) { lock.lock(); t = t.addingTimeInterval(s); lock.unlock() }
}
