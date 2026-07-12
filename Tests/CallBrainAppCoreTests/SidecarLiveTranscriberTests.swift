import Foundation
import Testing
@testable import CallBrainAppCore
@testable import CallBrainCore

@Suite("Live transcription sidecar (crash-isolated)")
struct SidecarLiveTranscriberTests {
    @Test("live-serve framing round-trips samples and segments")
    func framingRoundTrips() throws {
        let samples: [Float] = [0.1, -0.2, 0.3, 0.4, 1.5]
        let req = LiveServeProtocol.encodeRequest(samples)
        #expect(LiveServeProtocol.decodeLength(Data(req.prefix(4))) == samples.count)
        #expect(LiveServeProtocol.samples(from: Data(req.dropFirst(4))) == samples)

        let segs = [TranscribedSegment(text: "hi there", tStart: 0, tEnd: 1),
                    TranscribedSegment(text: "again", tStart: 1, tEnd: 2)]
        let resp = LiveServeProtocol.encodeResponse(segs)
        let len = try #require(LiveServeProtocol.decodeLength(Data(resp.prefix(4))))
        let json = Data(resp.dropFirst(4))
        #expect(json.count == len)
        #expect(try JSONDecoder().decode([TranscribedSegment].self, from: json) == segs)
    }

    @Test("a real serve child round-trips a transcribed window")
    func realChildRoundTrips() async throws {
        let dir = try Self.tempDir()
        let respFile = dir.appendingPathComponent("resp.bin")
        try LiveServeProtocol.encodeResponse([
            TranscribedSegment(text: "hello world", tStart: 0, tEnd: 1)
        ]).write(to: respFile)
        // Fake serve child: emit one framed response, then exit. (Small request fits the pipe buffer,
        // so it needn't read stdin.)
        let helper = try Self.writeHelper(in: dir, body: "cat \"\(respFile.path)\"\n")

        let t = SidecarLiveTranscriber(executableURL: helper, model: "x")
        let out = try await t.transcribe([Float](repeating: 0.1, count: 8000), progress: { _ in })
        t.shutdown()
        #expect(out == [TranscribedSegment(text: "hello world", tStart: 0, tEnd: 1)])
    }

    @Test("a missing live helper degrades to an empty window, never a crash")
    func missingHelperReturnsEmpty() async throws {
        let t = SidecarLiveTranscriber(executableURL: URL(fileURLWithPath: "/nonexistent/cbtranscribe"), model: "x")
        let out = try await t.transcribe([Float](repeating: 0, count: 100), progress: { _ in })
        #expect(out.isEmpty)
    }

    @Test("a live helper that dies mid-stream degrades to an empty window")
    func crashingHelperReturnsEmpty() async throws {
        let dir = try Self.tempDir()
        let helper = try Self.writeHelper(in: dir, body: "exit 1\n")   // dies immediately, writes nothing
        let t = SidecarLiveTranscriber(executableURL: helper, model: "x")
        let out = try await t.transcribe([Float](repeating: 0, count: 100), progress: { _ in })
        t.shutdown()
        #expect(out.isEmpty)
    }

    private static func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cb-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func writeHelper(in dir: URL, body: String) throws -> URL {
        let url = dir.appendingPathComponent("serve.sh")
        try ("#!/bin/sh\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}
