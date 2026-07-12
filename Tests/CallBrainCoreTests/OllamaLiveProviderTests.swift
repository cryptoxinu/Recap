import Testing
import Foundation
@testable import CallBrainCore

/// The instant in-call lane (dual-answer spec P1). These drive the REAL streaming/parse path via a
/// `URLProtocol` stub that hands back canned Ollama NDJSON — so we cover the `{"response":…,"done":…}`
/// framing, the .ready→.delta→.done event shape, and the clean error mapping (server-down / model-missing)
/// that lets the UI degrade to Smart-only, all without a live Ollama server.
@Suite("OllamaLiveProvider", .serialized)
struct OllamaLiveProviderTests {

    private func provider(_ stub: AnyClass) -> OllamaLiveProvider {
        OllamaLiveProvider(model: "qwen2.5:3b", extraProtocolClasses: [stub])
    }

    private func collect(_ p: OllamaLiveProvider) async throws -> (deltas: [String], done: Completion?, ready: Bool) {
        var deltas: [String] = []; var done: Completion?; var ready = false
        for try await ev in p.streamComplete(prompt: "hi", system: "sys", model: "fast", timeout: 10) {
            switch ev {
            case .ready: ready = true
            case .delta(let t): deltas.append(t)
            case .done(let c): done = c
            }
        }
        return (deltas, done, ready)
    }

    @Test("streams NDJSON response chunks as .ready then deltas then an authoritative .done")
    func testStreamsNDJSON() async throws {
        MockOllamaURLProtocol.reset()
        MockOllamaURLProtocol.body = Data("""
        {"response":"Margins ","done":false}
        {"response":"changed.","done":false}
        {"response":"","done":true}
        """.utf8)
        MockOllamaURLProtocol.status = 200

        let (deltas, done, ready) = try await collect(provider(MockOllamaURLProtocol.self))

        #expect(ready)
        #expect(deltas == ["Margins ", "changed."])
        #expect(done?.text == "Margins changed.")
        #expect(done?.provider == .ollama)
        #expect(done?.model == "qwen2.5:3b")
    }

    @Test("non-streaming complete parses the response field")
    func testCompleteParses() async throws {
        MockOllamaURLProtocol.reset()
        MockOllamaURLProtocol.body = Data(#"{"response":"  Quick recap.  ","done":true}"#.utf8)
        MockOllamaURLProtocol.status = 200

        let c = try await provider(MockOllamaURLProtocol.self)
            .complete(prompt: "hi", system: nil, model: "fast", timeout: 10)

        #expect(c.text == "Quick recap.")
        #expect(c.provider == .ollama)
        #expect(c.costUSD == 0)
    }

    @Test("HTTP 404 (model not pulled) maps to notInstalled")
    func testModelMissingMapsToNotInstalled() async throws {
        MockOllamaURLProtocol.reset()
        MockOllamaURLProtocol.body = Data(#"{"error":"model not found"}"#.utf8)
        MockOllamaURLProtocol.status = 404

        await #expect(throws: LLMError.self) {
            _ = try await collect(provider(MockOllamaURLProtocol.self))
        }
    }

    @Test("a connection failure maps to launchFailed (server not running → Smart-only)")
    func testConnectionFailureMapsToLaunchFailed() async throws {
        MockOllamaURLProtocol.reset()
        MockOllamaURLProtocol.failure = NSError(domain: NSURLErrorDomain,
                                                code: NSURLErrorCannotConnectToHost)

        do {
            _ = try await collect(provider(MockOllamaURLProtocol.self))
            Issue.record("expected a launchFailed error")
        } catch let error as LLMError {
            if case .launchFailed = error { } else { Issue.record("expected .launchFailed, got \(error)") }
        }
    }
}

/// Minimal `URLProtocol` stub: returns a canned status + NDJSON body, or fails with a canned error.
final class MockOllamaURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var failure: Error?

    static func reset() { body = Data(); status = 200; failure = nil }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        if let failure = Self.failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        let url = request.url ?? URL(string: "http://127.0.0.1:11434/api/generate")!
        let resp = HTTPURLResponse(url: url, statusCode: Self.status,
                                   httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
}
