import Foundation
import WhisperKit
import CallBrainCore

/// `Transcriber` backed by WhisperKit (CoreML Whisper, on-device). The model is downloaded + compiled on
/// first use and cached; subsequent runs are instant to load. Default `base` balances speed/accuracy on
/// Apple Silicon; `large-v3-turbo` is the high-accuracy option.
public final class WhisperKitTranscriber: CallBrainCore.Transcriber, @unchecked Sendable {
    public let modelID: String
    private let modelName: String
    private var whisper: WhisperKit?   // confined: the pipeline transcribes one recording at a time

    public init(model: String = "base") {
        self.modelName = model
        self.modelID = "whisperkit-\(model)"
    }

    public func transcribe(_ samples: [Float],
                           progress: @Sendable @escaping (Double) -> Void) async throws -> [TranscribedSegment] {
        let wk = try await ensure()
        progress(0.05)
        let results = try await wk.transcribe(audioArray: samples)
        progress(0.98)
        return results.flatMap(\.segments).compactMap { seg in
            let text = seg.text
                .replacingOccurrences(of: #"<\|[^>]*\|>"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return TranscribedSegment(text: text, tStart: Double(seg.start), tEnd: Double(seg.end))
        }
    }

    private func ensure() async throws -> WhisperKit {
        if let whisper { return whisper }
        do {
            let wk = try await WhisperKit(WhisperKitConfig(model: modelName))
            whisper = wk
            return wk
        } catch {
            throw TranscribeError.modelUnavailable("WhisperKit '\(modelName)': \(error.localizedDescription)")
        }
    }
}
