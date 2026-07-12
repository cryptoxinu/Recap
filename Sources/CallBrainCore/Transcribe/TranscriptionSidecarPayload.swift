import Foundation

/// JSON contract between `Recap.app` and the `cbtranscribe` helper. The helper runs WhisperKit/CoreML
/// out of process, writes this payload, and exits; the app then ingests the parsed transcript.
public struct TranscriptionSidecarPayload: Codable, Sendable, Equatable {
    public let transcript: ParsedTranscript
    public let diarizationRequested: Bool
    public let diarizationSucceeded: Bool

    public init(transcript: ParsedTranscript,
                diarizationRequested: Bool,
                diarizationSucceeded: Bool) {
        self.transcript = transcript
        self.diarizationRequested = diarizationRequested
        self.diarizationSucceeded = diarizationSucceeded
    }

    public init(output: TranscriptionPipeline.Output) {
        self.init(transcript: output.transcript,
                  diarizationRequested: output.diarizationRequested,
                  diarizationSucceeded: output.diarizationSucceeded)
    }
}

