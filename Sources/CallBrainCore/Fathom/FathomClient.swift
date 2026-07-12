import Foundation

/// Stored Fathom connection: the per-user API key (X-Api-Key) + the newest meeting time we've imported,
/// so each poll only asks for what's new.
public struct FathomCredentials: Codable, Sendable, Equatable {
    public var apiKey: String
    public var lastSync: Date?
    public init(apiKey: String, lastSync: Date? = nil) { self.apiKey = apiKey; self.lastSync = lastSync }
}

public protocol FathomCredentialStore: Sendable {
    func load() -> FathomCredentials?
    @discardableResult func save(_ c: FathomCredentials) -> Bool
    func clear()
}

/// One transcript line from Fathom: `{speaker, text, timestamp}`.
public struct FathomLine: Sendable, Equatable {
    public let speaker: String
    public let text: String
    public let tStart: Double
}

/// A Fathom meeting normalized for ingest. Parsed defensively (Fathom field names can vary across API
/// revisions) so an unexpected shape degrades gracefully instead of crashing.
public struct FathomMeeting: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String?
    public let createdAt: Date?
    public let durationSeconds: Int?
    public let lines: [FathomLine]
    public let summaryMarkdown: String?

    public var date: String? {
        guard let createdAt else { return nil }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current
        return f.string(from: createdAt)
    }

    /// Into the parser-output shape the ingest pipeline consumes (source = fathom).
    public func toParsedTranscript() -> ParsedTranscript {
        // Derive each line's END from the NEXT line's start (last line from the meeting duration) —
        // the API gives only line starts, and tEnd == tStart made every utterance zero-length, which
        // breaks citation time-ranges + the timeline (audit D6, matching the text Fathom parser).
        let utts = lines.enumerated().map { i, l -> ParsedUtterance in
            let nextStart = i + 1 < lines.count ? lines[i + 1].tStart : nil
            let end = nextStart ?? durationSeconds.map(Double.init) ?? l.tStart
            return ParsedUtterance(seq: i, speakerRaw: l.speaker.isEmpty ? "Speaker" : l.speaker,
                                   tStart: l.tStart, tEnd: max(l.tStart, end), text: l.text)
        }
        var speakers: [String] = []
        for u in utts where !speakers.contains(u.speakerRaw) { speakers.append(u.speakerRaw) }
        return ParsedTranscript(title: title, date: date, startedAt: createdAt, durationSeconds: durationSeconds,
                                source: .fathom, speakers: speakers, utterances: utts)
    }
}

/// Pure, testable parsing of the Fathom `/meetings` response → `[FathomMeeting]` + the pagination cursor.
/// Tolerant of key-name variation (id/recording_id, created_at/recording_start_time, etc.) and of
/// timestamps given as seconds, "HH:MM:SS", or ISO-8601.
public enum FathomParse {
    /// Returns nil when the body ISN'T valid JSON (a truncated/HTML/error body on a 2xx) — the caller must
    /// treat that as a retryable error, NOT a fully-drained page, or it could advance the watermark past
    /// real meetings forever (audit CRITICAL). A genuinely empty-but-valid response returns ([], nil).
    public static func meetings(from data: Data) -> (meetings: [FathomMeeting], nextCursor: String?)? {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let obj = root as? [String: Any]
        let arr = (obj?[firstKey(obj, ["items", "meetings", "data", "results", "recordings"])] as? [[String: Any]])
            ?? (root as? [[String: Any]]) ?? []
        let cursor = (obj?[firstKey(obj, ["next_cursor", "nextCursor", "cursor"])] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return (arr.compactMap(meeting(from:)), cursor)
    }

    static func meeting(from m: [String: Any]) -> FathomMeeting? {
        let id = (m[firstKey(m, ["id", "recording_id", "recordingId", "meeting_id", "share_id"])] as? CustomStringConvertible).map { "\($0)" }
        guard let id, !id.isEmpty else { return nil }
        let title = (m[firstKey(m, ["title", "meeting_title", "name"])] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let created = parseDate(m[firstKey(m, ["created_at", "createdAt", "recording_start_time", "recorded_at", "started_at"])])
        let durationS: Int? = {
            if let d = m[firstKey(m, ["duration_seconds", "duration"])] as? Int { return d }
            if let d = m[firstKey(m, ["duration_seconds", "duration"])] as? Double { return Int(d) }
            return nil
        }()
        let summary: String? = {
            if let s = m["default_summary"] as? [String: Any] { return s[firstKey(s, ["markdown_formatted", "markdown", "text"])] as? String }
            return m[firstKey(m, ["summary", "ai_summary"])] as? String
        }()
        let rawLines = (m[firstKey(m, ["transcript", "transcript_lines", "lines"])] as? [[String: Any]]) ?? []
        let lines = rawLines.compactMap(line(from:))
        return FathomMeeting(id: id, title: (title?.isEmpty == false) ? title : nil,
                             createdAt: created, durationSeconds: durationS, lines: lines, summaryMarkdown: summary)
    }

    static func line(from l: [String: Any]) -> FathomLine? {
        let text = (l[firstKey(l, ["text", "content", "transcript", "sentence"])] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let text, !text.isEmpty else { return nil }
        let speaker: String = {
            if let s = l[firstKey(l, ["speaker", "speaker_name", "name", "display_name"])] as? String { return s }
            if let s = l["speaker"] as? [String: Any], let n = s[firstKey(s, ["name", "display_name"])] as? String { return n }
            return ""
        }()
        let t = parseSeconds(l[firstKey(l, ["timestamp", "ts", "start", "start_time", "time", "offset"])])
        return FathomLine(speaker: speaker, text: text, tStart: t)
    }

    // MARK: helpers

    static func firstKey(_ d: [String: Any]?, _ keys: [String]) -> String {
        guard let d else { return keys.first ?? "" }
        return keys.first(where: { d[$0] != nil }) ?? (keys.first ?? "")
    }

    static func parseDate(_ v: Any?) -> Date? {
        if let s = v as? String {
            let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = iso.date(from: s) { return d }
            iso.formatOptions = [.withInternetDateTime]
            if let d = iso.date(from: s) { return d }
        }
        if let n = v as? Double { return Date(timeIntervalSince1970: n > 1e11 ? n / 1000 : n) }
        if let n = v as? Int { return Date(timeIntervalSince1970: Double(n > 100_000_000_000 ? n / 1000 : n)) }
        return nil
    }

    /// Transcript offset → seconds. Accepts a number (seconds), "HH:MM:SS"/"MM:SS", or returns 0.
    static func parseSeconds(_ v: Any?) -> Double {
        if let n = v as? Double { return n }
        if let n = v as? Int { return Double(n) }
        if let s = v as? String {
            if let n = Double(s) { return n }
            let parts = s.split(separator: ":").compactMap { Double($0) }
            if parts.count == 3 { return parts[0] * 3600 + parts[1] * 60 + parts[2] }
            if parts.count == 2 { return parts[0] * 60 + parts[1] }
        }
        return 0
    }
}

public enum FathomError: Error, Sendable { case notConnected, http(Int), unauthorized }

/// One pass of pagination. `complete` is true only when the cursor was walked to the END with no
/// truncation or rate-limit; otherwise `nextCursor` is where to resume so a backlog drains across polls
/// without re-fetching or skipping pages (audit CRITICAL).
public struct FathomPage: Sendable {
    public let meetings: [FathomMeeting]
    public let nextCursor: String?
    public let complete: Bool
}

/// Blocks the X-Api-Key from ever being re-sent to a non-Fathom host via an HTTP redirect (audit MED:
/// SSRF / credential exfiltration). Same-host redirects are allowed; any other host cancels the redirect.
final class FathomRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        let ok = request.url?.host.map { $0 == "api.fathom.ai" || $0.hasSuffix(".fathom.ai") } ?? false
        completionHandler(ok ? request : nil)   // nil → don't follow (so the key is never re-sent off-host)
    }
}

/// Polls the Fathom public API (https://api.fathom.ai/external/v1) for new meetings, transcript inline.
/// Auth is a per-user API key in the `X-Api-Key` header. Cursor-paginates; bounded per pass so one poll
/// can't blow the 60-req/min rate limit. No egress beyond api.fathom.ai (redirects to other hosts blocked).
public actor FathomClient {
    private let store: any FathomCredentialStore
    private let session: URLSession
    static let base = "https://api.fathom.ai/external/v1"

    public init(store: any FathomCredentialStore, session: URLSession? = nil) {
        self.store = store
        self.session = session ?? URLSession(configuration: .default, delegate: FathomRedirectGuard(), delegateQueue: nil)
    }

    /// Fetch meetings created after `since` (nil = full history), transcript + summary inline, resuming from
    /// `startCursor` if a previous pass was truncated. Walks up to `maxPages` per pass. The returned
    /// `FathomPage.complete`/`nextCursor` tell the caller whether the window was fully drained.
    public func fetch(since: Date?, startCursor: String? = nil, maxPages: Int = 8, pageSize: Int = 25) async throws -> FathomPage {
        guard let key = store.load()?.apiKey, !key.isEmpty else { throw FathomError.notConnected }
        var out: [FathomMeeting] = []
        var cursor = startCursor
        var pages = 0
        while true {
            guard let url = Self.meetingsURL(since: since, cursor: cursor, pageSize: pageSize) else {
                return FathomPage(meetings: out, nextCursor: cursor, complete: false)
            }
            var req = URLRequest(url: url)
            req.setValue(key, forHTTPHeaderField: "X-Api-Key")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.timeoutInterval = 60
            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 || code == 403 { throw FathomError.unauthorized }
            if code == 429 { return FathomPage(meetings: out, nextCursor: cursor, complete: false) }  // resume this page next poll
            guard (200..<300).contains(code) else { throw FathomError.http(code) }
            // A malformed 2xx body is an error, NOT a drained page — return incomplete so the watermark
            // holds and we retry, rather than skipping meetings (audit CRITICAL).
            guard let (meetings, next) = FathomParse.meetings(from: data) else {
                return FathomPage(meetings: out, nextCursor: cursor, complete: false)
            }
            out += meetings
            pages += 1
            cursor = next
            if next == nil { return FathomPage(meetings: out, nextCursor: nil, complete: true) }       // drained the window
            if pages >= maxPages { return FathomPage(meetings: out, nextCursor: next, complete: false) } // resume next poll
        }
    }

    static func meetingsURL(since: Date?, cursor: String?, pageSize: Int) -> URL? {
        var c = URLComponents(string: base + "/meetings")
        var items: [URLQueryItem] = [
            .init(name: "include_transcript", value: "true"),
            .init(name: "include_summary", value: "true"),
            .init(name: "limit", value: String(pageSize)),
        ]
        if let since {
            let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime]
            items.append(.init(name: "created_after", value: iso.string(from: since)))
        }
        if let cursor, !cursor.isEmpty { items.append(.init(name: "cursor", value: cursor)) }
        c?.queryItems = items
        return c?.url
    }
}
