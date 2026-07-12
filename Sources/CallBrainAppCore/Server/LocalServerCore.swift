import Foundation

/// Parsed HTTP/1.1 request used by the local extension bridge.
///
/// The parser intentionally accepts only the subset Recap serves: one request per connection,
/// UTF-8 headers, optional `Content-Length`, no chunked body support, and no filesystem paths.
public struct HTTPRequest: Sendable, Equatable {
    public struct Head: Sendable, Equatable {
        public let method: String
        public let path: String
        public let headers: [String: String]
        public let contentLength: Int
        public let headerByteCount: Int

        public init(method: String, path: String, headers: [String: String],
                    contentLength: Int, headerByteCount: Int) {
            self.method = method
            self.path = path
            self.headers = headers
            self.contentLength = contentLength
            self.headerByteCount = headerByteCount
        }
    }

    public let method: String
    public let path: String
    public let headers: [String: String]
    public let body: Data

    public init(method: String, path: String, headers: [String: String], body: Data) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
    }

    /// Parse a complete raw HTTP request. Returns `nil` for malformed or truncated input.
    public static func parse(_ data: Data, maxHeaderBytes: Int = LocalServerLimits.headerBytes,
                             maxBodyBytes: Int = LocalServerLimits.importBodyBytes) -> HTTPRequest? {
        guard let head = parseHead(data, maxHeaderBytes: maxHeaderBytes),
              head.contentLength <= maxBodyBytes else { return nil }
        let bodyStart = head.headerByteCount + LocalServerLimits.headerTerminator.count
        let total = bodyStart + head.contentLength
        guard data.count >= total else { return nil }
        let body = Data(data[bodyStart..<total])
        return HTTPRequest(method: head.method, path: head.path, headers: head.headers, body: body)
    }

    /// Parse the request line and headers once the `\r\n\r\n` terminator has arrived.
    public static func parseHead(_ data: Data,
                                 maxHeaderBytes: Int = LocalServerLimits.headerBytes) -> Head? {
        guard let range = data.range(of: LocalServerLimits.headerTerminator) else { return nil }
        let headerByteCount = range.lowerBound
        guard headerByteCount <= maxHeaderBytes else { return nil }
        guard let headerText = String(data: data[..<range.lowerBound], encoding: .utf8) else { return nil }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count == 3 else { return nil }

        let method = String(parts[0]).uppercased()
        let path = Self.normalizedPath(String(parts[1]))
        guard path.hasPrefix("/") else { return nil }
        guard String(parts[2]).hasPrefix("HTTP/1.") else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let key = String(line[..<colon])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return nil }
            headers = headers.merging([key: value]) { _, new in new }
        }

        let contentLength: Int
        if let raw = headers["content-length"] {
            guard let parsed = Int(raw), parsed >= 0 else { return nil }
            contentLength = parsed
        } else {
            contentLength = 0
        }

        return Head(method: method, path: path, headers: headers,
                    contentLength: contentLength, headerByteCount: headerByteCount)
    }

    private static func normalizedPath(_ target: String) -> String {
        let queryStart = target.firstIndex(of: "?") ?? target.endIndex
        return String(target[..<queryStart])
    }
}

/// Fixed request-size limits for the local extension bridge.
public enum LocalServerLimits {
    public static let headerBytes = 64 * 1_024
    public static let smallBodyBytes = 256 * 1_024
    public static let liveBodyBytes = 16 * 1_024
    public static let askBodyBytes = 32 * 1_024
    public static let importBodyBytes = 8 * 1_024 * 1_024
    public static let headerTerminator = Data([13, 10, 13, 10])

    public static func bodyBytes(for path: String) -> Int {
        switch path {
        case "/live", "/mic-state":
            liveBodyBytes
        case "/ask":
            askBodyBytes
        case "/import":
            importBodyBytes
        default:
            smallBodyBytes
        }
    }
}

/// Known local-server routes and their allowed request methods.
public enum LocalServerRoute: String, Sendable, Equatable {
    case health = "/health"
    case live = "/live"
    case ask = "/ask"
    case importTranscript = "/import"
    case micState = "/mic-state"
    case pair = "/pair"                  // UNauthenticated auto-pair (window + chrome-extension origin gated)
    case recordStart = "/record/start"   // start the app's recording from the extension
    case recordStop = "/record/stop"     // stop it
    case recordStatus = "/record/status" // poll recording state for the extension's indicator

    public init?(path: String) {
        self.init(rawValue: path)
    }

    public var allowedMethods: String {
        "\(primaryMethod), OPTIONS"
    }

    public func allows(method: String) -> Bool {
        method.uppercased() == primaryMethod
    }

    private var primaryMethod: String {
        switch self {
        case .health, .pair, .recordStatus:
            "GET"
        case .live, .ask, .importTranscript, .micState, .recordStart, .recordStop:
            "POST"
        }
    }
}

/// A snapshot of the app's recording state, surfaced to the extension's record indicator.
public struct RecordStatusSnapshot: Sendable, Equatable {
    public let recording: Bool
    public let processing: Bool
    public let elapsed: String
    public init(recording: Bool, processing: Bool, elapsed: String) {
        self.recording = recording; self.processing = processing; self.elapsed = elapsed
    }
}

/// Token-auth helpers shared by the server and tests.
public enum LocalServerAuth {
    /// Compare two UTF-8 strings without data-dependent early exit once lengths match.
    public static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }

        var diff: UInt8 = 0
        for index in left.indices {
            diff |= left[index] ^ right[index]
        }
        return diff == 0
    }

    /// `OPTIONS` is unauthenticated for CORS preflight; every other method must present the token.
    public static func requiresToken(method: String) -> Bool {
        method.uppercased() != "OPTIONS"
    }

    /// Accept either `Authorization: Bearer <token>` or `X-Recap-Token: <token>`.
    public static func isAuthorized(_ request: HTTPRequest, token: String) -> Bool {
        if let bearer = bearerToken(from: request.headers["authorization"]),
           constantTimeEquals(bearer, token) {
            return true
        }
        if let header = request.headers["x-callbrain-token"],
           constantTimeEquals(header, token) {
            return true
        }
        return false
    }

    /// The Recap extension's pinned origin. The extension's `manifest.json` carries a fixed public `key`,
    /// so its ID is deterministic (`lcmphiaobpklepliifghlmpdiblkfgpm`) regardless of load path — letting the
    /// app accept ONLY the real extension, not any other installed one (audit MED).
    public static let expectedExtensionOrigin = "chrome-extension://lcmphiaobpklepliifghlmpdiblkfgpm"

    /// Whether `/pair` may hand back the token: the user-initiated window must be open AND the request must
    /// come from the Recap extension's exact pinned origin. A real web page always sends its true https
    /// origin (refused); any OTHER installed extension has a different chrome-extension id (refused). A local
    /// native process could still spoof the origin, but only during the short user-opened window, and the
    /// token grants nothing beyond this loopback meeting API. Pure + testable.
    public static func pairAllowed(origin: String?, windowOpen: Bool) -> Bool {
        guard windowOpen, let origin else { return false }
        let normalized = origin.hasSuffix("/") ? String(origin.dropLast()) : origin
        return normalized == expectedExtensionOrigin
    }

    private static func bearerToken(from header: String?) -> String? {
        guard let header else { return nil }
        let parts = header.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return nil }
        return String(parts[1])
    }
}

/// CORS policy for the extension bridge. Origins are never reflected.
public enum LocalServerCORS {
    public static let allowOrigin = "*"
    public static let allowMethods = "POST, GET, OPTIONS"
    public static let allowHeaders = "authorization, x-callbrain-token, content-type"
    public static let maxAge = "600"

    public static func isPreflight(_ request: HTTPRequest) -> Bool {
        request.method.uppercased() == "OPTIONS"
    }
}

/// Formats Server-Sent Event frames for streamed live answers.
public enum SSEFrameFormatter {
    public static func data(_ delta: String) -> String {
        "data: \(jsonString(delta))\n\n"
    }

    public static func done() -> String {
        "event: done\ndata: {\"ok\":true}\n\n"
    }

    public static func error(message: String) -> String {
        let payload = jsonObject(["message": message])
        return "event: error\ndata: \(payload)\n\n"
    }

    private static func jsonString(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let encoded = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return encoded
    }

    private static func jsonObject(_ value: [String: String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: []),
              let encoded = String(data: data, encoding: .utf8) else {
            return "{\"message\":\"error\"}"
        }
        return encoded
    }
}
