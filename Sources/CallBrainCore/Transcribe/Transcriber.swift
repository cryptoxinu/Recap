import Foundation

/// One transcribed span with its time window (Phase 3). WhisperKit emits these (segment- or word-level);
/// the pipeline aligns them to diarized speakers.
public struct TranscribedSegment: Sendable, Equatable {
    public let text: String
    public let tStart: Double
    public let tEnd: Double
    public init(text: String, tStart: Double, tEnd: Double) {
        self.text = text; self.tStart = tStart; self.tEnd = tEnd
    }
}

/// One diarized speaker turn (who spoke when). FluidAudio emits these.
public struct SpeakerSegment: Sendable, Equatable {
    public let speaker: String       // e.g. "Speaker 1"
    public let tStart: Double
    public let tEnd: Double
    public init(speaker: String, tStart: Double, tEnd: Double) {
        self.speaker = speaker; self.tStart = tStart; self.tEnd = tEnd
    }
}

/// On-device speech-to-text over 16 kHz mono samples. The protocol decouples the pipeline from WhisperKit
/// so it's testable with a stub and swappable (Apple SpeechTranscriber / cloud upgrade) later.
public protocol Transcriber: Sendable {
    var modelID: String { get }
    func transcribe(_ samples: [Float], progress: @Sendable @escaping (Double) -> Void) async throws -> [TranscribedSegment]
}

/// On-device speaker diarization. Optional — without it, turns are single-speaker + `isInferredSpeaker`.
public protocol Diarizer: Sendable {
    func diarize(_ samples: [Float]) async throws -> [SpeakerSegment]
}

public enum TranscribeError: Error, Sendable, Equatable {
    case emptyAudio
    case modelUnavailable(String)
}

/// Midpoint alignment (docs/ARCHITECTURE Phase 3): assign each transcribed segment the diarized speaker
/// whose turn contains the segment's MIDPOINT, then merge consecutive same-speaker segments into
/// utterances. Pure + deterministic → unit-testable without any model.
public enum SpeakerAligner {
    public static func align(_ segments: [TranscribedSegment],
                             speakers: [SpeakerSegment]) -> [ParsedUtterance] {
        let inferred = speakers.isEmpty
        var merged: [(speaker: String, tStart: Double, tEnd: Double, text: String)] = []
        for seg in segments {
            let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            let speaker = speakerFor(midpoint: (seg.tStart + seg.tEnd) / 2, in: speakers) ?? "Speaker 1"
            if let last = merged.last, last.speaker == speaker {
                merged[merged.count - 1].tEnd = seg.tEnd
                merged[merged.count - 1].text += " " + text
            } else {
                merged.append((speaker, seg.tStart, seg.tEnd, text))
            }
        }
        return merged.enumerated().map { i, m in
            ParsedUtterance(seq: i, speakerRaw: m.speaker, speakerConfidence: inferred ? nil : 0.9,
                            tStart: m.tStart, tEnd: m.tEnd, text: m.text,
                            isInferredSpeaker: inferred, tsConfidence: .exact)
        }
    }

    /// The speaker whose turn contains `t`; else the nearest turn (handles small gaps); nil if none.
    static func speakerFor(midpoint t: Double, in speakers: [SpeakerSegment]) -> String? {
        if let hit = speakers.first(where: { t >= $0.tStart && t < $0.tEnd }) { return hit.speaker }
        return speakers.min(by: { distance($0, t) < distance($1, t) })?.speaker
    }
    private static func distance(_ s: SpeakerSegment, _ t: Double) -> Double {
        t < s.tStart ? s.tStart - t : t - s.tEnd
    }
}
