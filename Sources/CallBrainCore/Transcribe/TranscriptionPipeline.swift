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

    /// The transcript plus whether diarization actually ran — so the UI can warn when speakers weren't
    /// identified instead of silently presenting everything as one speaker (Codex P3 gate HIGH).
    public struct Output: Sendable, Equatable {
        public let transcript: ParsedTranscript
        public let diarizationRequested: Bool
        public let diarizationSucceeded: Bool
        public var speakersIdentified: Bool { diarizationSucceeded && transcript.speakers.count > 1 }
    }

    /// Run the full pipeline. `progress` reports (stage, 0…1) so the UI can show a real fraction.
    public func run(url: URL, title: String?, date: String?,
                    progress: @Sendable @escaping (Stage, Double) -> Void = { _, _ in }) async throws -> Output {
        progress(.decoding, 0)
        let samples = try await AudioDecoder.decode16kMono(url: url)
        guard !samples.isEmpty else { throw TranscribeError.emptyAudio }
        progress(.decoding, 1)

        progress(.transcribing, 0)
        let segments = try await transcriber.transcribe(samples) { p in progress(.transcribing, p) }
        progress(.transcribing, 1)

        var speakers: [SpeakerSegment] = []
        var diarizationSucceeded = false
        if let diarizer {
            progress(.diarizing, 0)
            do { speakers = try await diarizer.diarize(samples); diarizationSucceeded = true }
            catch { diarizationSucceeded = false }   // proceed single-speaker, but DON'T hide it (below)
            progress(.diarizing, 1)
        }

        progress(.finishing, 0)
        let utterances = SpeakerAligner.align(segments, speakers: speakers)
        // No speech found → don't persist an empty meeting (Codex P3 gate MED).
        guard !utterances.isEmpty else { throw TranscribeError.emptyAudio }
        let speakerLabels = orderedUnique(utterances.map(\.speakerRaw))
        let duration = Int(AudioDecoder.duration(samples: samples.count).rounded())
        progress(.finishing, 1)

        let transcript = ParsedTranscript(title: title ?? "Recorded meeting", date: date,
                                          startedAt: nil, durationSeconds: duration,
                                          source: .gmeetLocal, speakers: speakerLabels, utterances: utterances)
        return Output(transcript: transcript, diarizationRequested: diarizer != nil,
                      diarizationSucceeded: diarizationSucceeded)
    }

    private func orderedUnique(_ xs: [String]) -> [String] {
        var seen = Set<String>(); var out: [String] = []
        for x in xs where seen.insert(x).inserted { out.append(x) }
        return out
    }
}
