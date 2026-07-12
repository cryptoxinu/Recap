import Foundation

/// One transcribed span with its time window (Phase 3). WhisperKit emits these (segment- or word-level);
/// the pipeline aligns them to diarized speakers.
public struct TranscribedSegment: Sendable, Equatable, Codable {
    public let text: String
    public let tStart: Double
    public let tEnd: Double
    public init(text: String, tStart: Double, tEnd: Double) {
        self.text = text; self.tStart = tStart; self.tEnd = tEnd
    }
}

/// Length-prefixed framing for the persistent live-transcription helper (`cbtranscribe --serve`).
/// The app and the child are the same arch on the same machine, so sample bytes are passed natively;
/// the length prefix is big-endian for an unambiguous, alignment-safe header. A CoreML crash kills the
/// child mid-stream — the reader gets EOF (a short/failed read) and degrades to `[]` instead of the app
/// process dying, which is the whole point of the boundary.
public enum LiveServeProtocol {
    /// Read exactly `count` bytes, or nil on EOF / short read (child died).
    public static func readExactly(_ fh: FileHandle, _ count: Int) -> Data? {
        guard count > 0 else { return Data() }
        var buf = Data(); buf.reserveCapacity(count)
        while buf.count < count {
            guard let chunk = try? fh.read(upToCount: count - buf.count), !chunk.isEmpty else { return nil }
            buf.append(chunk)
        }
        return buf
    }

    public static func encodeLength(_ n: Int) -> Data {
        withUnsafeBytes(of: UInt32(n).bigEndian) { Data($0) }
    }
    public static func decodeLength(_ data: Data) -> Int? {
        guard data.count == 4 else { return nil }
        var v: UInt32 = 0
        withUnsafeMutableBytes(of: &v) { _ = data.copyBytes(to: $0, count: 4) }
        return Int(UInt32(bigEndian: v))
    }

    /// Request = [4-byte BE sample count][Float32 native samples].
    public static func encodeRequest(_ samples: [Float]) -> Data {
        var data = encodeLength(samples.count)
        samples.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
        return data
    }
    public static func samples(from data: Data) -> [Float] {
        let n = data.count / 4
        guard n > 0 else { return [] }
        var out = [Float](repeating: 0, count: n)
        _ = out.withUnsafeMutableBytes { dst in data.copyBytes(to: dst, count: n * 4) }
        return out
    }

    /// Response = [4-byte BE json length][JSON of [TranscribedSegment]].
    public static func encodeResponse(_ segments: [TranscribedSegment]) -> Data {
        let json = (try? JSONEncoder().encode(segments)) ?? Data("[]".utf8)
        var data = encodeLength(json.count)
        data.append(json)
        return data
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
    /// Pre-load + compile the model so the first real transcription is instant.
    func prewarm() async
}

public extension Transcriber {
    /// No-op default for stubs and transcribers that do not need model warmup.
    func prewarm() async {}
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

    /// A segment whose midpoint has NO diarized turn within `maxGapSeconds` (silence, hold music,
    /// crosstalk) — labeled honestly rather than force-attributed to a real speaker (audit D3).
    public static let unattributed = "Unknown"

    public static func align(_ segments: [TranscribedSegment],
                             speakers: [SpeakerSegment]) -> [ParsedUtterance] {
        var merged: [(speaker: String, matched: Bool, tStart: Double, tEnd: Double, text: String)] = []
        for seg in segments {
            let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            // A gap segment (speakerFor → nil) is NOT credibly any diarized speaker; label it
            // `Unknown` with NO confidence instead of a confident (0.8) wrong `Speaker 1` (audit D3).
            let hit = speakerFor(midpoint: (seg.tStart + seg.tEnd) / 2, in: speakers)
            let speaker = hit ?? Self.unattributed
            if let last = merged.last, last.speaker == speaker {
                merged[merged.count - 1].tEnd = seg.tEnd
                merged[merged.count - 1].text += " " + text
            } else {
                merged.append((speaker, hit != nil, seg.tStart, seg.tEnd, text))
            }
        }
        // Whisper timestamps are MODEL-DERIVED (not source-stamped) and "Speaker 1/2" are diarization
        // guesses, never explicit human labels → `.derived` + `isInferredSpeaker: true` always
        // (Codex P3 gate: CTM confidence semantics).
        return merged.enumerated().map { i, m in
            // 0.8 only for a run actually MATCHED to a diarized turn; an unattributed run carries
            // no speaker confidence (audit D3 — no false certainty on gap audio).
            let conf: Double? = (speakers.isEmpty || !m.matched) ? nil : 0.8
            return ParsedUtterance(seq: i, speakerRaw: m.speaker, speakerConfidence: conf,
                            tStart: m.tStart, tEnd: m.tEnd, text: m.text,
                            isInferredSpeaker: true, tsConfidence: .derived)
        }
    }

    /// DUAL-CHANNEL alignment (T3): the recording captured the founder's MIC and the remote participants'
    /// audio on SEPARATE channels, so we diarize ONLY the clean remote (system) channel and attribute each
    /// transcribed segment (from the accurate mixed audio) by STRICT containment: a segment whose midpoint
    /// sits inside a remote speaker's span is that remote speaker; ANY other segment is the FOUNDER — the
    /// text reached the transcript while the remote channel was silent, so it can only be his mic. This
    /// fixes group calls (remote people separated cleanly; the founder never mislabeled as "them") without
    /// the muddy N-way diarization of a mono mix. Pure + deterministic → unit-testable.
    public static func alignFounderVsRemote(_ segments: [TranscribedSegment],
                                            remoteSpeakers: [SpeakerSegment],
                                            founderName: String) -> [ParsedUtterance] {
        var merged: [(speaker: String, tStart: Double, tEnd: Double, text: String)] = []
        for seg in segments {
            let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            // Attribute by OVERLAP, not a single instant (audit MED): the remote spans (system channel) and
            // the transcribed segments (mixed channel) are independently segmented, so a brief remote blip
            // straddling a founder segment's midpoint must NOT steal the whole turn. Sum each remote
            // speaker's overlap with [tStart,tEnd]; attribute to the best remote speaker only if it covers at
            // least HALF the segment, otherwise it's the founder (his mic carried the rest).
            let duration = max(0.0001, seg.tEnd - seg.tStart)
            var overlapBySpeaker: [String: Double] = [:]
            for sp in remoteSpeakers {
                let overlap = min(seg.tEnd, sp.tEnd) - max(seg.tStart, sp.tStart)
                if overlap > 0 { overlapBySpeaker[sp.speaker, default: 0] += overlap }
            }
            let best = overlapBySpeaker.max { $0.value < $1.value }
            let speaker = (best.map { $0.value >= duration * 0.5 } ?? false) ? best!.key : founderName
            if let last = merged.last, last.speaker == speaker {
                merged[merged.count - 1].tEnd = seg.tEnd
                merged[merged.count - 1].text += " " + text
            } else {
                merged.append((speaker, seg.tStart, seg.tEnd, text))
            }
        }
        // Channel separation is a STRONG attribution signal (not a mono-diarization guess), so confidence is
        // high; but "Speaker 1/2" identities + model-derived timestamps still mean isInferredSpeaker/.derived.
        return merged.enumerated().map { i, m in
            ParsedUtterance(seq: i, speakerRaw: m.speaker, speakerConfidence: 0.85,
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
