import Foundation

/// Parses a Google Meet **"Notes by Gemini"** export — a STRUCTURED SUMMARY, not a verbatim transcript
/// (docs/ARCHITECTURE.md §4 calls Gemini Notes a "secondary signal, never the transcript"). It carries
/// the meeting title, date, participant list, topic sections, and `[Owner] Title: Description` action
/// items, but no per-speaker timestamps.
///
/// Operates on the doc's extracted text (a `.docx` is unzipped to text upstream until native Swift
/// docx reading lands in a later phase). Each non-empty line becomes a searchable note utterance under
/// the pseudo-speaker "Gemini Notes" with `tsConfidence = .none` — so citations are by meeting +
/// position and never fabricate a `00:00`. `title`/`date` are passed in (parsed from the filename).
public enum GeminiNotesParser {
    public static func parse(_ text: String, title: String? = nil, date: String? = nil) throws -> ParsedTranscript {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.contains("<w:") }   // drop blank + any leaked docx XML

        guard !lines.isEmpty else { throw ParseError.empty }

        let utterances = lines.enumerated().map { i, line in
            ParsedUtterance(seq: i, speakerRaw: "Gemini Notes", speakerConfidence: nil,
                            tStart: 0, tEnd: 0, text: line,
                            isInferredSpeaker: false, tsConfidence: .none)
        }
        return ParsedTranscript(title: title, date: date, startedAt: nil, durationSeconds: nil,
                                source: .gmeetGemini, speakers: ["Gemini Notes"], utterances: utterances)
    }

    /// "Jun 29, 2026" / "June 29, 2026" → "2026-06-29" (helper for callers extracting a date from text).
    public static func parseDate(_ s: String) -> String? {
        let months = ["jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
                      "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12]
        let parts = s.replacingOccurrences(of: ",", with: " ").split(separator: " ").map(String.init)
        guard parts.count >= 3,
              let mm = months[String(parts[0].lowercased().prefix(3))],
              let dd = Int(parts[1]), let yyyy = Int(parts[2]) else { return nil }
        return String(format: "%04d-%02d-%02d", yyyy, mm, dd)
    }
}
