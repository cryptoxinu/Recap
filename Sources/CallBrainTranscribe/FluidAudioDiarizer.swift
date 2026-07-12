import Foundation
import FluidAudio
import CallBrainCore

/// `Diarizer` backed by FluidAudio (on-device speaker segmentation). Models download on first use and
/// cache. Raw speaker ids are remapped to friendly "Speaker 1/2/…" in first-seen order.
public final class FluidAudioDiarizer: CallBrainCore.Diarizer, @unchecked Sendable {
    // Lock-guarded one-shot init Task (Codex P3 gate MED) — safe to cache + reuse one instance.
    private let lock = NSLock()
    private var loadTask: Task<Box<DiarizerManager>, Error>?

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
        let task: Task<Box<DiarizerManager>, Error> = lock.withLock {
            if let t = loadTask { return t }
            let t = Task { () throws -> Box<DiarizerManager> in
                do {
                    let models = try await DiarizerModels.downloadIfNeeded()
                    let m = DiarizerManager()
                    m.initialize(models: models)
                    return Box(m)
                } catch { throw TranscribeError.modelUnavailable("FluidAudio diarizer: \(error.localizedDescription)") }
            }
            loadTask = t
            return t
        }
        return try await task.value.value
    }
}
