import Foundation
import WhisperKit
import CallBrainCore

/// `Transcriber` backed by WhisperKit (CoreML Whisper, on-device). The model is downloaded + compiled on
/// first use and cached; subsequent runs are instant to load. Default `base` balances speed/accuracy on
/// Apple Silicon; `large-v3-turbo` is the high-accuracy option.
public final class WhisperKitTranscriber: CallBrainCore.Transcriber, @unchecked Sendable {
    public let modelID: String
    private let modelName: String
    // Lock-guarded one-shot init Task: concurrent callers share a single load (no double-init / data
    // race on the model — Codex P3 gate MED). Safe to cache + reuse one instance across recordings.
    private let lock = NSLock()
    private var loadTask: Task<Box<WhisperKit>, Error>?

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
        let task: Task<Box<WhisperKit>, Error> = lock.withLock {
            if let t = loadTask { return t }
            let t = Task { [modelName] () throws -> Box<WhisperKit> in
                do { return Box(try await WhisperKit(WhisperKitConfig(model: modelName))) }
                catch { throw TranscribeError.modelUnavailable("WhisperKit '\(modelName)': \(error.localizedDescription)") }
            }
            loadTask = t
            return t
        }
        return try await task.value.value
    }
}
