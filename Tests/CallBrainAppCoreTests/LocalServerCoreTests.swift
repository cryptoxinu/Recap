import Foundation
import Testing
@testable import CallBrainAppCore

@Suite("Local server core")
struct LocalServerCoreTests {
    @Test("HTTPRequest parses GET with no body and strips query")
    func testParseGETNoBody() throws {
        let raw = Data("GET /health?cache=1 HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8)

        let request = try #require(HTTPRequest.parse(raw))

        #expect(request.method == "GET")
        #expect(request.path == "/health")
        #expect(request.headers["host"] == "127.0.0.1")
        #expect(request.body.isEmpty)
    }

    @Test("HTTPRequest parses POST headers and Content-Length body")
    func testParsePOSTWithBody() throws {
        let body = #"{"speaker":"Alice","text":"hello"}"#
        let raw = Data("""
        POST /live HTTP/1.1\r
        HOST: localhost\r
        Content-Type: application/json\r
        Content-Length: \(body.utf8.count)\r
        \r
        \(body)
        """.utf8)

        let request = try #require(HTTPRequest.parse(raw))

        #expect(request.method == "POST")
        #expect(request.path == "/live")
        #expect(request.headers["host"] == "localhost")
        #expect(request.headers["content-type"] == "application/json")
        #expect(String(data: request.body, encoding: .utf8) == body)
    }

    @Test("HTTPRequest returns nil for truncated Content-Length body")
    func testParseTruncatedBody() {
        let raw = Data("""
        POST /ask HTTP/1.1\r
        Content-Length: 20\r
        \r
        {"query":"hi"}
        """.utf8)

        #expect(HTTPRequest.parse(raw) == nil)
    }

    @Test("constant-time token compare handles equal, unequal, and different-length values")
    func testConstantTimeCompare() {
        #expect(LocalServerAuth.constantTimeEquals("same-token", "same-token"))
        #expect(!LocalServerAuth.constantTimeEquals("same-token", "same-taken"))
        #expect(!LocalServerAuth.constantTimeEquals("same-token", "same-token-extra"))
    }

    @Test("MeetSession appends, de-dupes prefix growth, formats transcript, resets, and caps turns")
    func testMeetSessionDedupeTranscriptResetAndCap() {
        let session = MeetSession(maxTurns: 3)

        session.append(speaker: " Alice ", text: " hello ")
        session.append(speaker: "Alice", text: "hello world")
        session.append(speaker: "Alice", text: "hello")
        session.append(speaker: "Bob", text: "ok")

        #expect(session.transcript() == "Alice: hello world\nBob: ok")
        #expect(!session.isEmpty)

        session.append(speaker: "Carol", text: "third")
        session.append(speaker: "Dana", text: "fourth")
        #expect(session.transcript() == "Bob: ok\nCarol: third\nDana: fourth")

        session.reset()
        #expect(session.isEmpty)
        #expect(session.transcript() == "")
    }

    @Test("MeetSession replaces a provisional caption in place (incl. non-prefix revision), appends after final")
    func testMeetSessionProvisionalReplace() {
        let session = MeetSession()
        // Live caption for one utterance, revised in place — including a NON-prefix ASR correction.
        session.append(speaker: "Alice", text: "I think we", final: false)
        session.append(speaker: "Alice", text: "I think we should", final: false)
        session.append(speaker: "Alice", text: "I think we shall proceed", final: false)  // non-prefix revision
        #expect(session.transcript() == "Alice: I think we shall proceed")   // ONE line, not three

        session.append(speaker: "Alice", text: "I think we shall proceed", final: true)   // finalize
        session.append(speaker: "Alice", text: "Next point entirely", final: false)       // new utterance → append
        #expect(session.transcript() == "Alice: I think we shall proceed\nAlice: Next point entirely")
    }

    @Test("MeetSession truncates stored turns and caps retained transcript bytes")
    func testMeetSessionTruncatesAndCapsBytes() throws {
        let truncating = MeetSession(maxTurns: 10, maxTotalBytes: 10_000)
        truncating.append(speaker: String(repeating: "A", count: 130),
                          text: String(repeating: "x", count: 4_100))

        let stored = truncating.transcript()
        let separator = try #require(stored.firstIndex(of: ":"))
        let storedSpeaker = String(stored[..<separator])
        let textStart = stored.index(separator, offsetBy: 2)
        let storedText = String(stored[textStart...])

        #expect(storedSpeaker.count == 120)
        #expect(storedText.count == 4_000)

        let byteCapped = MeetSession(maxTurns: 10, maxTotalBytes: 24)
        byteCapped.append(speaker: "A", text: "1234567890")
        byteCapped.append(speaker: "B", text: "1234567890")

        #expect(byteCapped.transcript() == "B: 1234567890")
        #expect(byteCapped.transcript().utf8.count <= 24)
    }

    @Test("route body limits keep live and ask requests smaller than imports")
    func testRouteBodyLimits() {
        #expect(LocalServerLimits.bodyBytes(for: "/live") == 16 * 1_024)
        #expect(LocalServerLimits.bodyBytes(for: "/mic-state") == 16 * 1_024)
        #expect(LocalServerLimits.bodyBytes(for: "/ask") == 32 * 1_024)
        #expect(LocalServerLimits.bodyBytes(for: "/import") == 8 * 1_024 * 1_024)
        #expect(LocalServerLimits.bodyBytes(for: "/health") == 256 * 1_024)
    }

    @Test("mic-state POST routes, authorizes, and decodes a valid mute body")
    func testMicStatePOSTRoutesAuthorizesAndDecodes() throws {
        let request = try #require(HTTPRequest.parse(
            Self.request(method: "POST", path: "/mic-state", body: #"{"muted":true}"#,
                         headers: ["Authorization": "Bearer local-secret"]),
            maxBodyBytes: LocalServerLimits.bodyBytes(for: "/mic-state")
        ))

        let payload = try JSONDecoder().decode(MicStateProbe.self, from: request.body)

        #expect(request.path == "/mic-state")
        #expect(LocalServerRoute(path: request.path) == .micState)
        #expect(LocalServerRoute.micState.allows(method: request.method))
        #expect(LocalServerAuth.isAuthorized(request, token: "local-secret"))
        #expect(payload.muted)
    }

    @Test("mic-state rejects malformed bodies and missing tokens")
    func testMicStateRejectsMalformedBodyAndMissingToken() throws {
        let malformed = try #require(HTTPRequest.parse(
            Self.request(method: "POST", path: "/mic-state", body: #"{"muted":"true"}"#,
                         headers: ["Authorization": "Bearer local-secret"]),
            maxBodyBytes: LocalServerLimits.bodyBytes(for: "/mic-state")
        ))
        let missingToken = try #require(HTTPRequest.parse(
            Self.request(method: "POST", path: "/mic-state", body: #"{"muted":false}"#),
            maxBodyBytes: LocalServerLimits.bodyBytes(for: "/mic-state")
        ))

        #expect(LocalServerRoute(path: malformed.path) == .micState)
        #expect((try? JSONDecoder().decode(MicStateProbe.self, from: malformed.body)) == nil)
        #expect(LocalServerRoute.micState.allows(method: missingToken.method))
        #expect(LocalServerAuth.requiresToken(method: missingToken.method))
        #expect(!LocalServerAuth.isAuthorized(missingToken, token: "local-secret"))
    }

    @Test("new routes parse with their methods (pair/record)")
    func testNewRoutesAndMethods() {
        #expect(LocalServerRoute(path: "/pair") == .pair)
        #expect(LocalServerRoute.pair.allows(method: "GET"))
        #expect(!LocalServerRoute.pair.allows(method: "POST"))
        #expect(LocalServerRoute(path: "/record/start") == .recordStart)
        #expect(LocalServerRoute.recordStart.allows(method: "POST"))
        #expect(LocalServerRoute(path: "/record/stop") == .recordStop)
        #expect(LocalServerRoute.recordStop.allows(method: "POST"))
        #expect(LocalServerRoute(path: "/record/status") == .recordStatus)
        #expect(LocalServerRoute.recordStatus.allows(method: "GET"))
        #expect(!LocalServerRoute.recordStatus.allows(method: "POST"))
    }

    @Test("pairAllowed: only the PINNED CallBrain extension origin during an OPEN window")
    func testPairAllowed() {
        let ok = LocalServerAuth.expectedExtensionOrigin   // the pinned CallBrain extension id
        // Allowed: the exact pinned extension origin + open window (with or without a trailing slash).
        #expect(LocalServerAuth.pairAllowed(origin: ok, windowOpen: true))
        #expect(LocalServerAuth.pairAllowed(origin: ok + "/", windowOpen: true))
        // Refused: a DIFFERENT installed extension (audit MED — was previously allowed).
        #expect(!LocalServerAuth.pairAllowed(origin: "chrome-extension://aaaabbbbccccddddeeeeffffgggghhhh", windowOpen: true))
        // Refused: a real web page (true https origin) even with the window open.
        #expect(!LocalServerAuth.pairAllowed(origin: "https://evil.example.com", windowOpen: true))
        #expect(!LocalServerAuth.pairAllowed(origin: "https://meet.google.com", windowOpen: true))
        // Refused: no origin, or window closed.
        #expect(!LocalServerAuth.pairAllowed(origin: nil, windowOpen: true))
        #expect(!LocalServerAuth.pairAllowed(origin: ok, windowOpen: false))
    }

    @Test("SSE data frame JSON-escapes quotes and newlines")
    func testSSEFrameEscapesDelta() throws {
        let delta = "hello \"Z\"\nnext line"
        let frame = SSEFrameFormatter.data(delta)

        #expect(frame.hasPrefix("data: "))
        #expect(frame.hasSuffix("\n\n"))

        let payloadStart = frame.index(frame.startIndex, offsetBy: "data: ".count)
        let payloadEnd = frame.index(frame.endIndex, offsetBy: -2)
        let payload = String(frame[payloadStart..<payloadEnd])
        let decoded = try JSONDecoder().decode(String.self, from: Data(payload.utf8))

        #expect(decoded == delta)
        #expect(!payload.contains("\n"))
    }

    @Test("token gate accepts bearer or extension header and CORS preflight skips auth")
    func testTokenGateAndCORSPreflight() {
        let bearer = HTTPRequest(method: "GET", path: "/health",
                                 headers: ["authorization": "Bearer local-secret"], body: Data())
        let extensionHeader = HTTPRequest(method: "GET", path: "/health",
                                          headers: ["x-callbrain-token": "local-secret"], body: Data())
        let wrong = HTTPRequest(method: "GET", path: "/health",
                                headers: ["authorization": "Bearer wrong"], body: Data())
        let options = HTTPRequest(method: "OPTIONS", path: "/anything",
                                  headers: ["origin": "chrome-extension://abc"], body: Data())

        #expect(LocalServerAuth.isAuthorized(bearer, token: "local-secret"))
        #expect(LocalServerAuth.isAuthorized(extensionHeader, token: "local-secret"))
        #expect(!LocalServerAuth.isAuthorized(wrong, token: "local-secret"))
        #expect(LocalServerAuth.requiresToken(method: "GET"))
        #expect(!LocalServerAuth.requiresToken(method: "OPTIONS"))
        #expect(LocalServerCORS.isPreflight(options))
        #expect(LocalServerCORS.allowOrigin == "*")
    }

    private static func request(method: String, path: String, body: String,
                                headers: [String: String] = [:]) -> Data {
        let headerLines = headers.map { "\($0.key): \($0.value)" }.joined(separator: "\r\n")
        let extraHeaders = headerLines.isEmpty ? "" : "\(headerLines)\r\n"
        return Data("""
        \(method) \(path) HTTP/1.1\r
        Host: 127.0.0.1\r
        Content-Type: application/json\r
        \(extraHeaders)Content-Length: \(body.utf8.count)\r
        \r
        \(body)
        """.utf8)
    }
}

private struct MicStateProbe: Decodable, Equatable {
    let muted: Bool
}
