import Testing
import Foundation
@testable import CallBrainCore

@Suite("CodexRunner streaming")
struct CodexRunnerStreamingTests {

    static let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/codex-json/hello.ndjson")

    private func fakeCodex(_ body: String) throws -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-codex-\(UUID().uuidString).sh").path
        try "#!/bin/bash\n\(body)\n".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    private func collect(_ runner: CodexRunner) async throws -> (ready: Bool, deltas: [String], done: Completion?) {
        var ready = false
        var deltas: [String] = []
        var done: Completion?
        for try await ev in runner.streamComplete(prompt: "hi", system: "sys", model: "ignored", timeout: 10) {
            switch ev {
            case .ready: ready = true
            case .delta(let text): deltas.append(text)
            case .done(let completion): done = completion
            }
        }
        return (ready, deltas, done)
    }

    @Test("codex --json item.completed agent messages become deltas then done")
    func streamsItemCompletedMessages() async throws {
        let body = """
        out=""
        while [[ $# -gt 0 ]]; do
          case "$1" in
            -o|--output-last-message) out="$2"; shift 2 ;;
            *) shift ;;
          esac
        done
        cat '\(Self.fixtureURL.path)'
        [[ -n "$out" ]] && printf 'Hello world' > "$out"
        """
        let runner = CodexRunner(executablePath: try fakeCodex(body),
                                 sandboxDir: FileManager.default.temporaryDirectory.path,
                                 model: "gpt-5-codex")

        let result = try await collect(runner)
        #expect(result.ready)
        #expect(result.deltas == ["Hello", " world"])
        #expect(result.done?.text == "Hello world")
        #expect(result.done?.provider == .codex)
        #expect(result.done?.model == "gpt-5-codex")
    }

    @Test("codex streamed error envelopes surface as providerError")
    func providerErrorEnvelope() async throws {
        let body = #"echo '{"type":"error","subtype":"invalid_request","message":"bad request"}'"#
        let runner = CodexRunner(executablePath: try fakeCodex(body),
                                 sandboxDir: FileManager.default.temporaryDirectory.path)
        do {
            _ = try await collect(runner)
            Issue.record("stream should have thrown providerError")
        } catch let e as LLMError {
            if case .providerError(let subtype, let detail) = e {
                #expect(subtype == "invalid_request")
                #expect(detail == "bad request")
            } else {
                Issue.record("wrong error: \(e)")
            }
        }
    }

    @Test("codex non-zero streaming exit maps to nonZeroExit")
    func nonZeroExit() async throws {
        let runner = CodexRunner(executablePath: try fakeCodex("echo transient >&2; exit 42"),
                                 sandboxDir: FileManager.default.temporaryDirectory.path)
        do {
            _ = try await collect(runner)
            Issue.record("stream should have thrown nonZeroExit")
        } catch let e as LLMError {
            if case .nonZeroExit(let code, let stderr) = e {
                #expect(code == 42)
                #expect(stderr.contains("transient"))
            } else {
                Issue.record("wrong error: \(e)")
            }
        }
    }
}
