import Foundation
import CallBrainCore

public enum TranscriptionSidecarError: LocalizedError, Sendable, Equatable {
    case helperUnavailable(String)
    case childFailed(status: Int32, stderr: String)
    case missingOutput(String)
    case invalidOutput(String)
    /// The recording contained no detectable speech (helper exit 3). An EXPECTED outcome, not a
    /// crash — the caller creates a findable placeholder meeting rather than dropping the recording.
    case noSpeech

    /// The helper's dedicated exit code for "no speech found" (`cbtranscribe` emptyAudio → exit 3).
    public static let noSpeechExitCode: Int32 = 3

    /// Whether this failure warrants retrying with a DIFFERENT (lighter) model. Only a child crash/error
    /// (`childFailed` — e.g. WhisperKit's MLTensor SIGTRAP) can be model-specific and worth escalating; a
    /// clean no-speech, a missing helper, or unreadable output won't change with another model.
    public var isModelSpecificFailure: Bool {
        if case .childFailed = self { return true }
        return false
    }

    public var errorDescription: String? {
        switch self {
        case .helperUnavailable(let path):
            return "Transcription helper is missing at \(path). Reinstall Recap and retry; your audio file was kept."
        case .childFailed(let status, let stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let suffix = detail.isEmpty ? "" : " \(String(detail.prefix(240)))"
            return "Transcription failed in the helper process (exit \(status)).\(suffix) Your audio file was kept; retry this import."
        case .missingOutput(let path):
            return "Transcription helper finished without writing \(path). Your audio file was kept; retry this import."
        case .invalidOutput(let reason):
            return "Transcription helper returned an unreadable result: \(reason). Your audio file was kept; retry this import."
        case .noSpeech:
            return "No speech was detected in that recording."
        }
    }
}

public enum TranscriptionSidecarRunner {
    public static func run(executableURL: URL,
                           audioURL: URL,
                           outputURL: URL,
                           title: String,
                           date: String?,
                           model: String?,
                           diarize: Bool,
                           systemAudioURL: URL? = nil,
                           founderName: String? = nil,
                           timeout: TimeInterval = 60 * 60 * 4) async throws -> TranscriptionSidecarPayload {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw TranscriptionSidecarError.helperUnavailable(executableURL.path)
        }
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: outputURL)

        let args = arguments(audioURL: audioURL, outputURL: outputURL,
                             title: title, date: date, model: model, diarize: diarize,
                             systemAudioURL: systemAudioURL, founderName: founderName)
        let result = try await ChildProcess.run(executable: executableURL.path,
                                                args: args,
                                                timeout: timeout)
        guard result.exitCode == 0 else {
            if result.exitCode == TranscriptionSidecarError.noSpeechExitCode {
                throw TranscriptionSidecarError.noSpeech
            }
            throw TranscriptionSidecarError.childFailed(status: result.exitCode, stderr: result.stderr)
        }
        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            throw TranscriptionSidecarError.missingOutput(outputURL.path)
        }
        do {
            let data = try Data(contentsOf: outputURL)
            return try JSONDecoder().decode(TranscriptionSidecarPayload.self, from: data)
        } catch {
            throw TranscriptionSidecarError.invalidOutput(error.localizedDescription)
        }
    }

    static func arguments(audioURL: URL,
                          outputURL: URL,
                          title: String,
                          date: String?,
                          model: String?,
                          diarize: Bool,
                          systemAudioURL: URL? = nil,
                          founderName: String? = nil) -> [String] {
        var args = [
            "--json-output", outputURL.path,
            "--title", title,
        ]
        if let date, !date.isEmpty { args += ["--date", date] }
        if let model, !model.isEmpty { args += ["--model", model] }
        if !diarize { args.append("--no-diarize") }
        // Dual-channel group attribution (T3): the clean remote-only track + the founder's name to label
        // his turns. Only meaningful together; the sidecar ignores one without the other.
        if let systemAudioURL, let founderName, !founderName.isEmpty {
            args += ["--system-audio", systemAudioURL.path, "--founder", founderName]
        }
        args.append(audioURL.path)
        return args
    }
}

