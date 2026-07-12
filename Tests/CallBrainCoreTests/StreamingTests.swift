import Testing
import Foundation
@testable import CallBrainCore

/// Perfection plan Task 3.2 — token streaming from the CLI. The audit's #1 product-killer:
/// 40-50s of spinner because `claude -p` ran with buffered `--output-format json`. These tests
/// drive the REAL subprocess path via tiny shell-script stand-ins + the recorded NDJSON fixture,
/// covering the judge-required freeze-history cases (cancellation kills the child, stderr is
/// drained, EOF-without-result throws, inactivity timeout).
@Suite("Streaming provider (stream-json)")
struct StreamingTests {

    static let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/stream-json/hello.ndjson")

    /// Write an executable shell script standing in for the claude CLI.
    private func fakeCLI(_ body: String) throws -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-claude-\(UUID().uuidString).sh").path
        try "#!/bin/bash\n\(body)\n".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    private func runner(_ exe: String) -> ClaudeRunner {
        ClaudeRunner(executablePath: exe, sandboxDir: FileManager.default.temporaryDirectory.path)
    }

    private func collect(_ r: ClaudeRunner, timeout: TimeInterval = 10) async throws -> (deltas: [String], done: Completion?) {
        var deltas: [String] = []; var done: Completion?
        for try await ev in r.streamComplete(prompt: "hi", system: nil, model: "sonnet", timeout: timeout) {
            switch ev {
            case .ready: break
            case .delta(let t): deltas.append(t)
            case .done(let c): done = c
            }
        }
        return (deltas, done)
    }

    @Test("parses the recorded fixture into deltas then done")
    func testParsesFixtureDeltasAndDone() async throws {
        let exe = try fakeCLI("cat '\(Self.fixtureURL.path)'")
        let (deltas, done) = try await collect(runner(exe))
        #expect(!deltas.isEmpty)
        #expect(deltas.joined() == "Hello!")
        #expect(done?.text == "Hello!")
        #expect(done?.provider == .claude)
    }

    @Test("EOF without a result line throws after partial deltas")
    func testEOFWithoutDoneThrowsAfterPartials() async throws {
        // Everything except the final `result` line.
        let exe = try fakeCLI("grep -v '\"type\":\"result\"' '\(Self.fixtureURL.path)'")
        var sawDelta = false
        do {
            for try await ev in runner(exe).streamComplete(prompt: "hi", system: nil, model: "sonnet", timeout: 10) {
                if case .delta = ev { sawDelta = true }
            }
            Issue.record("stream should have thrown at EOF without result")
        } catch { /* expected */ }
        #expect(sawDelta)
    }

    @Test("inactivity timeout fires when the child stalls mid-stream")
    func testInactivityTimeout() async throws {
        let exe = try fakeCLI("head -5 '\(Self.fixtureURL.path)'; sleep 30")
        do {
            _ = try await collect(runner(exe), timeout: 2)
            Issue.record("should have timed out")
        } catch let e as LLMError {
            if case .timedOut = e {} else { Issue.record("wrong error: \(e)") }
        }
    }

    @Test("cancelling the consumer terminates the CLI child (no quota leak)")
    func testStreamCancellationTerminatesSubprocess() async throws {
        let marker = "cbstream-\(UUID().uuidString)"
        let exe = try fakeCLI("echo start; sleep 30 # \(marker)")
        let task = Task {
            try await collect(runner(exe), timeout: 60)
        }
        try await Task.sleep(for: .milliseconds(600))   // let it spawn
        task.cancel()
        _ = try? await task.value
        // The child must be gone within 2s of cancellation.
        var alive = true
        for _ in 0..<20 {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            p.arguments = ["-f", marker]; p.standardOutput = Pipe(); p.standardError = Pipe()
            try p.run(); p.waitUntilExit()
            alive = (p.terminationStatus == 0)
            if !alive { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(!alive)
    }

    @Test("a stderr flood during streaming cannot deadlock the pipe")
    func testStderrDrainedDuringStreaming() async throws {
        // 300KB to stderr (≫ the 64KB pipe buffer) BEFORE stdout — deadlocks if undrained.
        let exe = try fakeCLI("dd if=/dev/zero bs=1024 count=300 2>/dev/null | tr '\\0' 'x' 1>&2; cat '\(Self.fixtureURL.path)'")
        let (deltas, done) = try await collect(runner(exe))
        #expect(deltas.joined() == "Hello!")
        #expect(done != nil)
    }
}

/// Router streaming semantics (Task 3.2 S4): availability fallback ONLY before the first delta.
@Suite("ProviderRouter streaming fallback")
struct RouterStreamingTests {

    final class ScriptedStreamer: LLMProvider, @unchecked Sendable {
        let events: [Result<StreamEvent, LLMError>]
        let pid: ProviderID
        init(_ pid: ProviderID, _ events: [Result<StreamEvent, LLMError>]) { self.pid = pid; self.events = events }
        nonisolated var id: ProviderID { pid }
        func complete(prompt: String, system: String?, model: String, timeout: TimeInterval) async throws -> Completion {
            Completion(text: "buffered", provider: pid, model: model, usage: TokenUsage(), costUSD: 0)
        }
        func completeJSON(prompt: String, system: String?, schema: String, model: String, timeout: TimeInterval) async throws -> String { "{}" }
        func streamComplete(prompt: String, system: String?, model: String, timeout: TimeInterval) -> AsyncThrowingStream<StreamEvent, Error> {
            AsyncThrowingStream { c in
                for r in events {
                    switch r {
                    case .success(let ev): c.yield(ev)
                    case .failure(let e): c.finish(throwing: e); return
                    }
                }
                c.finish()
            }
        }
    }

    private func doneEvent(_ pid: ProviderID) -> StreamEvent {
        .done(Completion(text: "ok", provider: pid, model: "m", usage: TokenUsage(), costUSD: 0))
    }

    @Test("availability failure BEFORE any delta falls back to the secondary")
    func testFallsBackBeforeFirstDelta() async throws {
        let primary = ScriptedStreamer(.claude, [.failure(.launchFailed("down"))])
        let secondary = ScriptedStreamer(.codex, [.success(.delta("hi")), .success(doneEvent(.codex))])
        let router = ProviderRouter(claude: primary, codex: secondary, primary: .claude)
        var deltas: [String] = []; var done: Completion?
        for try await ev in router.streamComplete(prompt: "q", system: nil, model: "m", timeout: 10) {
            if case .delta(let t) = ev { deltas.append(t) }
            if case .done(let c) = ev { done = c }
        }
        #expect(deltas == ["hi"])
        #expect(done?.provider == .codex)
    }

    @Test("a failure AFTER the first delta surfaces — no silent mid-answer engine swap")
    func testNoFallbackAfterFirstDelta() async throws {
        let primary = ScriptedStreamer(.claude, [.success(.delta("partial")), .failure(.timedOut(seconds: 1))])
        let secondary = ScriptedStreamer(.codex, [.success(doneEvent(.codex))])
        let router = ProviderRouter(claude: primary, codex: secondary, primary: .claude)
        var deltas: [String] = []
        do {
            for try await ev in router.streamComplete(prompt: "q", system: nil, model: "m", timeout: 10) {
                if case .delta(let t) = ev { deltas.append(t) }
            }
            Issue.record("should have thrown after the partial delta")
        } catch { /* expected */ }
        #expect(deltas == ["partial"])
    }
}

/// Codex phase-3 HIGH regression: a streamed error envelope must surface as providerError —
/// never be swallowed into decodeFailed (which the router treats as an availability failure).
@Suite("Streamed error envelopes")
struct StreamedErrorEnvelopeTests {
    @Test("is_error=true result line throws providerError, not decodeFailed")
    func testErrorEnvelopeSurfaces() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-claude-err-\(UUID().uuidString).sh").path
        let errLine = #"{"type":"result","subtype":"error_during_execution","is_error":true,"result":"Invalid model"}"#
        try "#!/bin/bash\necho '\(errLine)'\n".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        let r = ClaudeRunner(executablePath: path, sandboxDir: FileManager.default.temporaryDirectory.path)
        do {
            for try await _ in r.streamComplete(prompt: "hi", system: nil, model: "sonnet", timeout: 10) {}
            Issue.record("should have thrown providerError")
        } catch let e as LLMError {
            if case .providerError = e {} else { Issue.record("wrong error: \(e)") }
        }
    }
}
