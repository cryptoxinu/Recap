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
    /// A diarized turn this far (s) from a transcript segment's midpoint is NOT credibly the speaker —
    /// the segment likely sits in silence/hold-music. Beyond it, fall back rather than mis-attribute.
    static let maxGapSeconds = 3.0

    public static func align(_ segments: [TranscribedSegment],
                             speakers: [SpeakerSegment]) -> [ParsedUtterance] {
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
        // Whisper timestamps are MODEL-DERIVED (not source-stamped) and "Speaker 1/2" are diarization
        // guesses, never explicit human labels → `.derived` + `isInferredSpeaker: true` always
        // (Codex P3 gate: CTM confidence semantics).
        return merged.enumerated().map { i, m in
            ParsedUtterance(seq: i, speakerRaw: m.speaker, speakerConfidence: speakers.isEmpty ? nil : 0.8,
                            tStart: m.tStart, tEnd: m.tEnd, text: m.text,
                            isInferredSpeaker: true, tsConfidence: .derived)
        }
    }

    /// The speaker whose turn contains `t`; else the nearest turn IF within `maxGapSeconds` (so a segment
    /// in a long gap isn't attributed to a speaker minutes away — P3 gate MED); nil otherwise.
    static func speakerFor(midpoint t: Double, in speakers: [SpeakerSegment]) -> String? {
        if let hit = speakers.first(where: { t >= $0.tStart && t < $0.tEnd }) { return hit.speaker }
        guard let nearest = speakers.min(by: { distance($0, t) < distance($1, t) }) else { return nil }
        return distance(nearest, t) <= maxGapSeconds ? nearest.speaker : nil
    }
    private static func distance(_ s: SpeakerSegment, _ t: Double) -> Double {
        t < s.tStart ? s.tStart - t : t - s.tEnd
    }
}
