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
    ///
    /// DUAL-CHANNEL (T3): when `systemAudioURL` (the remote-participants-only channel) and `founderName`
    /// are supplied, we still transcribe the accurate MIXED `url` for text, but diarize the CLEAN system
    /// channel for the remote speakers and attribute every non-remote segment to the founder — so a group
    /// call reads as "You / <real remote speakers>" instead of the muddy N-way diarization of a mono mix.
    /// When they're absent (old recordings, non-recording imports), it's the original mono behavior.
    public func run(url: URL, title: String?, date: String?,
                    systemAudioURL: URL? = nil, founderName: String? = nil,
                    progress: @Sendable @escaping (Stage, Double) -> Void = { _, _ in }) async throws -> Output {
        progress(.decoding, 0)
        let samples = try await AudioDecoder.decode16kMono(url: url)
        guard !samples.isEmpty else { throw TranscribeError.emptyAudio }
        progress(.decoding, 1)

        progress(.transcribing, 0)
        let segments = try await transcriber.transcribe(samples) { p in progress(.transcribing, p) }
        progress(.transcribing, 1)

        // Decide the attribution source: dual-channel remote diarization when we have a usable system track.
        let dual = try await remoteSamples(systemAudioURL: systemAudioURL, founderName: founderName)

        var speakers: [SpeakerSegment] = []
        var diarizationSucceeded = false
        var useDual = false
        if let diarizer {
            progress(.diarizing, 0)
            if let dual {
                // Diarize the CLEAN remote channel. Use founder-vs-remote attribution ONLY if it yields real
                // speakers — an empty/failed remote pass (silent/too-short/undecodable sibling) must NOT
                // blanket-relabel the whole call as the founder (audit HIGH). Fall back to diarizing the
                // MIXED audio exactly like the pre-T3 mono path.
                let remote = (try? await diarizer.diarize(dual.samples)) ?? []
                if !remote.isEmpty {
                    speakers = remote; diarizationSucceeded = true; useDual = true
                } else {
                    do { speakers = try await diarizer.diarize(samples); diarizationSucceeded = true }
                    catch { diarizationSucceeded = false }
                }
            } else {
                do { speakers = try await diarizer.diarize(samples); diarizationSucceeded = true }
                catch { diarizationSucceeded = false }   // proceed single-speaker, but DON'T hide it (below)
            }
            progress(.diarizing, 1)
        }

        progress(.finishing, 0)
        let utterances: [ParsedUtterance]
        if useDual, let dual {
            // Remote channel diarized cleanly → founder-vs-remote attribution (any non-remote span = founder).
            utterances = SpeakerAligner.alignFounderVsRemote(segments, remoteSpeakers: speakers,
                                                             founderName: dual.founderName)
        } else {
            // No system track, empty remote diarization, or diarization failed → original midpoint alignment.
            utterances = SpeakerAligner.align(segments, speakers: speakers)
        }
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

    /// Decode the remote (system-only) channel for dual-channel attribution, or nil to use the mono path.
    /// A missing/empty/undecodable system track quietly degrades to mono rather than failing the whole pass.
    private func remoteSamples(systemAudioURL: URL?, founderName: String?)
        async throws -> (samples: [Float], founderName: String)? {
        guard let systemAudioURL, let founderName, !founderName.isEmpty,
              FileManager.default.fileExists(atPath: systemAudioURL.path) else { return nil }
        guard let samples = try? await AudioDecoder.decode16kMono(url: systemAudioURL), !samples.isEmpty
        else { return nil }
        return (samples, founderName)
    }

    private func orderedUnique(_ xs: [String]) -> [String] {
        var seen = Set<String>(); var out: [String] = []
        for x in xs where seen.insert(x).inserted { out.append(x) }
        return out
    }
}
