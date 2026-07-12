import Foundation
import Testing
@testable import CallBrainAppCore
@testable import CallBrainCore

@Suite("Transcription sidecar runner")
struct TranscriptionSidecarRunnerTests {
    @Test("non-zero child exit becomes a retryable error and preserves the source audio")
    func failedChildPreservesAudio() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cb-sidecar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let audio = dir.appendingPathComponent("meeting.wav")
        try Data("not real audio".utf8).write(to: audio)
        let output = dir.appendingPathComponent("result.json")
        let helper = try Self.writeHelper(in: dir, body: "exit 7\n")

        await #expect(throws: TranscriptionSidecarError.self) {
            _ = try await TranscriptionSidecarRunner.run(
                executableURL: helper,
                audioURL: audio,
                outputURL: output,
                title: "Meeting",
                date: "2026-07-07",
                model: "tiny",
                diarize: false,
                timeout: 5
            )
        }
        #expect(FileManager.default.fileExists(atPath: audio.path))
    }

    @Test("successful child output decodes a transcript sidecar")
    func decodesSuccessfulSidecar() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cb-sidecar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let audio = dir.appendingPathComponent("meeting.wav")
        try Data("not real audio".utf8).write(to: audio)
        let output = dir.appendingPathComponent("result.json")
        let helper = try Self.writeHelper(in: dir, body: """
        out=""
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --json-output) out="$2"; shift 2 ;;
            *) shift ;;
          esac
        done
        cat > "$out" <<'JSON'
        {"transcript":{"title":"Meeting","date":"2026-07-07","startedAt":null,"durationSeconds":1,"source":"gmeet_local","speakers":["Speaker 1"],"utterances":[{"seq":0,"speakerRaw":"Speaker 1","speakerConfidence":null,"tStart":0,"tEnd":1,"text":"Hello there.","isInferredSpeaker":true,"tsConfidence":"derived"}]},"diarizationRequested":false,"diarizationSucceeded":false}
        JSON
        exit 0
        """)

        let sidecar = try await TranscriptionSidecarRunner.run(
            executableURL: helper,
            audioURL: audio,
            outputURL: output,
            title: "Meeting",
            date: "2026-07-07",
            model: "tiny",
            diarize: false,
            timeout: 5
        )

        #expect(sidecar.transcript.title == "Meeting")
        #expect(sidecar.transcript.utterances.first?.text == "Hello there.")
        #expect(sidecar.diarizationRequested == false)
    }

    @Test("dual-channel args include --system-audio + --founder only when both present (T3)")
    func dualChannelArguments() {
        let audio = URL(fileURLWithPath: "/tmp/meeting.wav")
        let output = URL(fileURLWithPath: "/tmp/out.json")
        let system = URL(fileURLWithPath: "/tmp/.meeting.system.wav")

        let withDual = TranscriptionSidecarRunner.arguments(
            audioURL: audio, outputURL: output, title: "Meeting", date: "2026-07-08",
            model: "turbo", diarize: true, systemAudioURL: system, founderName: "Alex")
        #expect(withDual.contains("--system-audio"))
        #expect(withDual.contains(system.path))
        #expect(withDual.contains("--founder"))
        #expect(withDual.contains("Alex"))
        #expect(withDual.last == audio.path)   // positional audio stays last

        // A system track WITHOUT a founder name (or vice-versa) is meaningless → omit both.
        let noFounder = TranscriptionSidecarRunner.arguments(
            audioURL: audio, outputURL: output, title: "Meeting", date: nil,
            model: nil, diarize: true, systemAudioURL: system, founderName: nil)
        #expect(!noFounder.contains("--system-audio"))
        #expect(!noFounder.contains("--founder"))

        // The ordinary mono import (no dual args) is unchanged.
        let mono = TranscriptionSidecarRunner.arguments(
            audioURL: audio, outputURL: output, title: "Meeting", date: nil, model: nil, diarize: true)
        #expect(!mono.contains("--system-audio"))
    }

    private static func writeHelper(in dir: URL, body: String) throws -> URL {
        let url = dir.appendingPathComponent("helper.sh")
        try ("#!/bin/sh\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}

