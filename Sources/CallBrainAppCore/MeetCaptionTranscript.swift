import Foundation
import CallBrainCore

/// A Google Meet **live CC caption** transcript captured via the Chrome-extension bridge — the exact,
/// speaker-NAMED turns Meet itself produced.
///
/// Why this exists (T2, 2026-07-08): the recording path re-transcribes the mixed mic+system WAV with
/// on-device WhisperKit, which is both less accurate on real calls and can only guess "You"/"Them" for
/// speakers. When the extension was relaying captions during a recording, those captions are strictly
/// better — accurate text AND real participant names — so we persist them as a sidecar next to the WAV
/// and let the import pipeline PREFER them over WhisperKit. Captions are a best-effort accelerant, never
/// a hard dependency: a missing/empty/garbage sidecar simply falls back to WhisperKit.
public struct MeetCaptionTranscript: Codable, Sendable, Equatable {
    public var title: String?
    public var date: String?          // "YYYY-MM-DD"
    public var turns: [CaptionTurn]

    public init(title: String? = nil, date: String? = nil, turns: [CaptionTurn]) {
        self.title = title
        self.date = date
        self.turns = turns
    }

    /// The sidecar file that sits next to a recording's WAV: `<wav-stem>.cbcaptions`. The extension is
    /// deliberately NOT one the importer reads (`IngestEngine.readableExtensions`), so a folder scan that
    /// reaches the Recordings directory never mistakes a sidecar for a transcript to ingest (audit LOW).
    /// Its contents are still JSON — this type encodes/decodes it explicitly.
    public static func sidecarURL(forRecording wav: URL) -> URL {
        wav.deletingPathExtension().appendingPathExtension("cbcaptions")
    }

    /// Encode + atomically write the sidecar. Throws so the caller can log a write failure (the WAV still
    /// imports via WhisperKit, so a failed sidecar write degrades to the audio path, never data loss).
    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// Decode a sidecar if it exists AND carries at least one usable turn. Returns nil on any
    /// missing/corrupt/empty file so the caller cleanly falls back to WhisperKit.
    public static func read(from url: URL) -> MeetCaptionTranscript? {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(MeetCaptionTranscript.self, from: data),
              decoded.turns.contains(where: {
                  !$0.speaker.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              })
        else { return nil }
        return decoded
    }

    /// Build the ingest-ready transcript. Meet's real speaker names are kept verbatim (high confidence);
    /// captions carry NO timecodes, so — matching the Gemini-notes convention — every turn is
    /// `tStart/tEnd = 0` with `tsConfidence = .none`, and order is preserved by `seq`.
    public func parsed() -> ParsedTranscript {
        var speakers: [String] = []
        var seen = Set<String>()
        var utterances: [ParsedUtterance] = []
        for turn in turns {
            let name = turn.speaker.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !text.isEmpty else { continue }
            if seen.insert(name).inserted { speakers.append(name) }
            utterances.append(ParsedUtterance(
                seq: utterances.count, speakerRaw: name, speakerConfidence: 1.0,
                tStart: 0, tEnd: 0, text: text, isInferredSpeaker: false, tsConfidence: .none))
        }
        return ParsedTranscript(title: title, date: date, source: .gmeetCaptions,
                                speakers: speakers, utterances: utterances)
    }

    /// True when there is at least one usable named turn to ingest.
    public var hasContent: Bool {
        turns.contains {
            !$0.speaker.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}
