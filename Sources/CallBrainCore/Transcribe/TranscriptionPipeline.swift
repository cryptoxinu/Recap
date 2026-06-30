import Foundation

/// Turns a raw recording into a citable, diarized transcript meeting (Phase 3):
/// decode (AVFoundation) → transcribe (WhisperKit) → diarize (FluidAudio) → midpoint-align → CTM.
/// The result is a `ParsedTranscript` the existing `IngestEngine` ingests like any other source, so a
/// transcribed call gets the same chunks/embeddings/entities/AskFred as a pasted one.
public struct TranscriptionPipeline: Sendable {
    public let transcriber: any Transcriber
    public let diarizer: (any Diarizer)?

    public init(transcriber: any Transcriber, diarizer: (any Diarizer)? = nil) {
        self.transcriber = transcriber; self.diarizer = diarizer
    }

    public enum Stage: Sendable, Equatable { case decoding, transcribing, diarizing, finishing }

    /// Run the full pipeline. `progress` reports (stage, 0…1) so the UI can show a real fraction.
    public func run(url: URL, title: String?, date: String?,
                    progress: @Sendable @escaping (Stage, Double) -> Void = { _, _ in }) async throws -> ParsedTranscript {
        progress(.decoding, 0)
        let samples = try await AudioDecoder.decode16kMono(url: url)
        guard !samples.isEmpty else { throw TranscribeError.emptyAudio }
        progress(.decoding, 1)

        progress(.transcribing, 0)
        let segments = try await transcriber.transcribe(samples) { p in progress(.transcribing, p) }
        progress(.transcribing, 1)

        var speakers: [SpeakerSegment] = []
        if let diarizer {
            progress(.diarizing, 0)
            speakers = (try? await diarizer.diarize(samples)) ?? []   // diarization is best-effort
            progress(.diarizing, 1)
        }

        progress(.finishing, 0)
        let utterances = SpeakerAligner.align(segments, speakers: speakers)
        let speakerLabels = orderedUnique(utterances.map(\.speakerRaw))
        let duration = Int(AudioDecoder.duration(samples: samples.count).rounded())
        progress(.finishing, 1)

        return ParsedTranscript(title: title ?? "Recorded meeting", date: date,
                                startedAt: nil, durationSeconds: duration,
                                source: .gmeetLocal, speakers: speakerLabels, utterances: utterances)
    }

    private func orderedUnique(_ xs: [String]) -> [String] {
        var seen = Set<String>(); var out: [String] = []
        for x in xs where seen.insert(x).inserted { out.append(x) }
        return out
    }
}
