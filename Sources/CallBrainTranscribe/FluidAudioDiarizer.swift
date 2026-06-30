import Foundation
import FluidAudio
import CallBrainCore

/// `Diarizer` backed by FluidAudio (on-device speaker segmentation). Models download on first use and
/// cache. Raw speaker ids are remapped to friendly "Speaker 1/2/…" in first-seen order.
public final class FluidAudioDiarizer: CallBrainCore.Diarizer, @unchecked Sendable {
    private var manager: DiarizerManager?   // confined: diarizes one recording at a time

    public init() {}

    public func diarize(_ samples: [Float]) async throws -> [SpeakerSegment] {
        let m = try await ensure()
        let result = try m.performCompleteDiarization(samples, sampleRate: AudioDecoder.targetSampleRate)

        var labelFor: [String: String] = [:]
        func label(_ raw: String) -> String {
            if let l = labelFor[raw] { return l }
            let l = "Speaker \(labelFor.count + 1)"; labelFor[raw] = l; return l
        }
        return result.segments.map {
            SpeakerSegment(speaker: label($0.speakerId),
                           tStart: Double($0.startTimeSeconds), tEnd: Double($0.endTimeSeconds))
        }
    }

    private func ensure() async throws -> DiarizerManager {
        if let manager { return manager }
        do {
            let models = try await DiarizerModels.downloadIfNeeded()
            let m = DiarizerManager()
            m.initialize(models: models)
            manager = m
            return m
        } catch {
            throw TranscribeError.modelUnavailable("FluidAudio diarizer: \(error.localizedDescription)")
        }
    }
}
