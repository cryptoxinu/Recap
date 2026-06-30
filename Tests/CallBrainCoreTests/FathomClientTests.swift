import Testing
import Foundation
@testable import CallBrainCore

@Suite("Fathom API parsing + URL builder")
struct FathomClientTests {

    private func data(_ s: String) -> Data { Data(s.utf8) }

    @Test("parses the documented /meetings shape: id, title, date, transcript, summary, cursor")
    func parseDocumented() throws {
        let json = """
        {"items":[
          {"id":"rec_123","title":"Ambient Sync","created_at":"2026-06-30T17:00:00Z",
           "default_summary":{"template_name":"general","markdown_formatted":"## Recap\\n- shipped"},
           "transcript":[
             {"speaker":"Zade","text":"Let's start.","timestamp":0},
             {"speaker":"Max","text":"Agreed.","timestamp":"00:01:05"}
           ]}
        ],"next_cursor":"abc"}
        """
        let (meetings, cursor) = try #require(FathomParse.meetings(from: data(json)))
        #expect(cursor == "abc")
        #expect(meetings.count == 1)
        let m = meetings[0]
        #expect(m.id == "rec_123")
        #expect(m.title == "Ambient Sync")
        #expect(m.date == { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current
                            return f.string(from: m.createdAt!) }())
        #expect(m.summaryMarkdown?.contains("Recap") == true)
        #expect(m.lines.count == 2)
        #expect(m.lines[0].speaker == "Zade")
        #expect(m.lines[1].tStart == 65)        // "00:01:05" → 65s
    }

    @Test("tolerates alternate key names (recording_id, content) + nested speaker")
    func parseAlternateKeys() throws {
        let json = """
        {"meetings":[
          {"recording_id":"r9","meeting_title":"Quick chat","recording_start_time":1782800000,
           "transcript":[{"speaker":{"name":"Ghazal"},"content":"Hi","start":12.5}]}
        ]}
        """
        let (meetings, cursor) = try #require(FathomParse.meetings(from: data(json)))
        #expect(cursor == nil)
        #expect(meetings.first?.id == "r9")
        #expect(meetings.first?.title == "Quick chat")
        #expect(meetings.first?.lines.first?.speaker == "Ghazal")
        #expect(meetings.first?.lines.first?.tStart == 12.5)
    }

    @Test("a bare array (no wrapper object) still parses")
    func parseBareArray() throws {
        let json = #"[{"id":"x","title":"T","transcript":[{"speaker":"A","text":"hello"}]}]"#
        let (meetings, _) = try #require(FathomParse.meetings(from: data(json)))
        #expect(meetings.count == 1)
        #expect(meetings[0].lines.first?.text == "hello")
        #expect(meetings[0].lines.first?.tStart == 0)   // missing timestamp → 0
    }

    @Test("malformed (non-JSON) input returns nil so the caller retries; valid-empty returns empty")
    func parseGarbage() throws {
        #expect(FathomParse.meetings(from: data("not json")) == nil)   // malformed → nil (retryable)
        #expect(FathomParse.meetings(from: Data()) == nil)
        #expect(FathomParse.meetings(from: data("{}"))?.meetings.isEmpty == true)   // valid-empty → []
        // a meeting with no id is dropped; a line with no text is dropped
        let (m, _) = try #require(FathomParse.meetings(from: data(#"{"items":[{"title":"no id"},{"id":"ok","transcript":[{"speaker":"A"}]}]}"#)))
        #expect(m.count == 1 && m[0].id == "ok" && m[0].lines.isEmpty)
    }

    @Test("toParsedTranscript yields a fathom-sourced transcript with distinct speakers")
    func toParsed() {
        let m = FathomMeeting(id: "1", title: "Sync", createdAt: Date(timeIntervalSince1970: 1_782_800_000),
                              durationSeconds: 600,
                              lines: [.init(speaker: "Zade", text: "a", tStart: 0),
                                      .init(speaker: "Max", text: "b", tStart: 5),
                                      .init(speaker: "Zade", text: "c", tStart: 9)],
                              summaryMarkdown: nil)
        let p = m.toParsedTranscript()
        #expect(p.source == .fathom)
        #expect(p.title == "Sync")
        #expect(p.speakers == ["Zade", "Max"])     // distinct, first-seen order
        #expect(p.utterances.count == 3)
        #expect(p.utterances[1].speakerRaw == "Max")
    }

    @Test("meetingsURL includes transcript + created_after + cursor")
    func urlBuilder() throws {
        let since = Date(timeIntervalSince1970: 1_782_800_000)
        let u = try #require(FathomClient.meetingsURL(since: since, cursor: "c1", pageSize: 25))
        let q = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(u.absoluteString.hasPrefix("https://api.fathom.ai/external/v1/meetings"))
        #expect(q.contains { $0.name == "include_transcript" && $0.value == "true" })
        #expect(q.contains { $0.name == "cursor" && $0.value == "c1" })
        #expect(q.contains { $0.name == "created_after" })
    }

    @Test("fetch: drains pages → complete; truncation by maxPages → incomplete + resume cursor")
    func fetchPagination() async throws {
        // Stateless stub: first page carries next_cursor=c2; the c2 page ends the walk.
        FathomStubProtocol.handler = { req in
            let cursor = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "cursor" }?.value
            let body = cursor == "c2"
                ? #"{"items":[{"id":"b","transcript":[{"speaker":"X","text":"two"}]}]}"#
                : #"{"items":[{"id":"a","transcript":[{"speaker":"X","text":"one"}]}],"next_cursor":"c2"}"#
            return (200, Data(body.utf8))
        }
        let cfg = URLSessionConfiguration.ephemeral; cfg.protocolClasses = [FathomStubProtocol.self]
        let client = FathomClient(store: InMemoryFathomStore(FathomCredentials(apiKey: "k")),
                                  session: URLSession(configuration: cfg))

        let full = try await client.fetch(since: nil, startCursor: nil, maxPages: 8)
        #expect(full.complete)
        #expect(full.nextCursor == nil)
        #expect(full.meetings.map(\.id) == ["a", "b"])

        // Same data, but only one page allowed → not complete, resumes at c2.
        let trunc = try await client.fetch(since: nil, startCursor: nil, maxPages: 1)
        #expect(!trunc.complete)
        #expect(trunc.nextCursor == "c2")
        #expect(trunc.meetings.map(\.id) == ["a"])
    }
}

/// Dedicated URLProtocol stub for the Fathom networked test (stateless handler → safe under parallel tests).
final class FathomStubProtocol: URLProtocol, @unchecked Sendable {
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
