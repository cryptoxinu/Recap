import Foundation

/// Universal "paste anything" importer (founder request): drop in a raw transcript dump in ANY format
/// and get a structured, named meeting back.
///
/// Strategy = deterministic-first, AI-fallback:
///  1. If the text is a recognized format (Fireflies JSON, Fireflies copy `Name: H:MM:SS`, Fathom),
///     parse it deterministically — fast, exact, free.
///  2. Otherwise hand the raw text to the LLM (`claude --json-schema`) which normalizes ANY layout into
///     the canonical {title, date, participants, utterances[{speaker, timestamp_seconds, text}]}.
///  3. Always ensure a title (generated if the source has none) so every import is named.
public struct AIImporter: Sendable {
    public let llm: ClaudeRunner
    public init(llm: ClaudeRunner) { self.llm = llm }

    public enum Format: String, Sendable, Equatable {
        case firefliesJSON, firefliesCopy, fathom, geminiNotes, unknown
    }

    public struct Resolved: Sendable, Equatable {
        public let transcript: ParsedTranscript
        public let format: Format
        public let usedAI: Bool
    }

    // MARK: - detection (deterministic, testable offline)

    private nonisolated(unsafe) static let copyHeaderRE = try! NSRegularExpression(
        pattern: #"(?m)^\s*.{1,40}?:\s+\d{1,2}:\d{2}(?::\d{2})?\s*$"#)
    // Real Fathom headers: bare form `Name  M:SS` (timecode at END, text on the next line) OR paren
    // form `Name (M:SS): text`. Requiring the bare timecode to end the line stops a mid-sentence
    // timecode in prose ("latency 0:45 being a problem") from being counted as a header (audit M4).
    private nonisolated(unsafe) static let fathomHeaderRE = try! NSRegularExpression(
        pattern: #"(?m)^\s*.{1,40}?(?:\s+\d{1,2}:\d{2}(?::\d{2})?\s*$|\(\d{1,2}:\d{2}(?::\d{2})?\)\s*:?.*$)"#)

    /// Classify by *header density*, not raw counts. The discriminator is the fraction of non-empty
    /// lines that are timecode/speaker headers: a transcript is MOSTLY headers; Gemini notes (a summary)
    /// are almost none; prose-with-stray-timecodes is neither → AI-resolve. (Codex/SME audit: a Fathom
    /// `.docx` with bold colon-less `Travis 0:00` lines was mis-routing to Gemini, and a single-section
    /// notes paste with incidental timecodes was being shredded as Fathom.)
    public static func detect(_ raw: String) -> Format {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("{") || t.hasPrefix("[") {
            if t.contains("\"sentences\"") || t.contains("\"speaker_name\"") || t.contains("\"transcript\"") {
                return .firefliesJSON
            }
        }
        let full = NSRange(location: 0, length: (t as NSString).length)
        let copyHits = copyHeaderRE.numberOfMatches(in: t, range: full)
        let fathomHits = fathomHeaderRE.numberOfMatches(in: t, range: full)
        let nonEmpty = max(1, t.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count)
        let headerFraction = Double(copyHits + fathomHits) / Double(nonEmpty)
        let geminiHeaders = t.components(separatedBy: "\n").filter { $0.hasPrefix("## ") }.count

        // Gemini notes: ≥2 `## ` sections AND headers are a tiny fraction of lines (summary, not transcript).
        if geminiHeaders >= 2 && headerFraction < 0.25 { return .geminiNotes }
        // Transcripts: ≥3 timecode headers. No fraction floor here — the tightened regexes already
        // require the timecode to anchor a header line (end-of-line / paren form), so prose with a stray
        // mid-sentence timecode doesn't count; and a verbose real transcript with long multi-line turns
        // (low header density) must still classify deterministically, not fall to AI-resolve (re-audit MED).
        if copyHits >= 3 { return .firefliesCopy }
        if fathomHits >= 3 { return .fathom }
        return .unknown
    }

    /// Exposed for tests: does this read as Gemini notes?
    static func looksLikeGeminiNotes(_ t: String) -> Bool { detect(t) == .geminiNotes }

    // MARK: - resolve

    /// Resolve a raw dump into a structured, named meeting. `titleHint`/`dateHint` come from the source
    /// filename (e.g. "morning sync - 2026_06_29 … Notes by Gemini.docx") and seed any parser that lacks
    /// in-band metadata (Gemini notes carry no machine-readable title/date of their own).
    public func resolve(_ raw: String, generateTitleIfMissing: Bool = true,
                        titleHint: String? = nil, dateHint: String? = nil) async throws -> Resolved {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ParseError.empty }

        switch Self.detect(trimmed) {
        case .firefliesJSON:
            return try await finalize(FirefliesParser.parse(Data(trimmed.utf8)), .firefliesJSON, raw: trimmed,
                                      shouldGenerateTitle: generateTitleIfMissing, titleHint: titleHint, dateHint: dateHint)
        case .firefliesCopy:
            return try await finalize(FirefliesCopyParser.parse(trimmed), .firefliesCopy, raw: trimmed,
                                      shouldGenerateTitle: generateTitleIfMissing, titleHint: titleHint, dateHint: dateHint)
        case .fathom:
            return try await finalize(FathomParser.parse(trimmed), .fathom, raw: trimmed,
                                      shouldGenerateTitle: generateTitleIfMissing, titleHint: titleHint, dateHint: dateHint)
        case .geminiNotes:
            // A summary, not a transcript: route to the notes parser, seeded with filename title/date.
            let parsed = try GeminiNotesParser.parse(trimmed, title: titleHint, date: dateHint)
            return try await finalize(parsed, .geminiNotes, raw: trimmed,
                                      shouldGenerateTitle: generateTitleIfMissing, titleHint: titleHint, dateHint: dateHint)
        case .unknown:
            var p = try await aiResolve(trimmed)
            if let titleHint, p.title == nil || p.title == "Imported call" { p.title = titleHint }
            if let dateHint, p.date == nil { p.date = dateHint }
            return Resolved(transcript: p, format: .unknown, usedAI: true)
        }
    }

    private func finalize(_ parsed: ParsedTranscript, _ fmt: Format, raw: String,
                          shouldGenerateTitle: Bool, titleHint: String? = nil, dateHint: String? = nil) async throws -> Resolved {
        var p = parsed
        if let dateHint, p.date == nil { p.date = dateHint }
        if (p.title?.isEmpty ?? true), let titleHint, !titleHint.isEmpty { p.title = titleHint }
        if shouldGenerateTitle, (p.title?.isEmpty ?? true) {
            p.title = (try? await generateTitle(forSpeakers: p.speakers, sample: raw)) ?? defaultTitle(p)
        }
        return Resolved(transcript: p, format: fmt, usedAI: false)
    }

    private func defaultTitle(_ p: ParsedTranscript) -> String {
        let who = p.speakers.prefix(2).joined(separator: " / ")
        return who.isEmpty ? "Imported call" : "\(who) call"
    }

    // MARK: - AI paths

    private static let extractionSystem = """
    You convert a raw meeting transcript or notes — in ANY format — into structured JSON.
    Rules: preserve EVERY utterance and its speaker; do not summarize, merge, drop, or invent content.
    If timestamps exist in any format, convert each to seconds from start; if none, use null.
    Provide a concise 4–8 word title describing the meeting. Output ONLY JSON matching the schema.
    """

    private static let extractionSchema = """
    {"type":"object","additionalProperties":false,"required":["title","utterances"],
     "properties":{
       "title":{"type":"string"},
       "date":{"type":["string","null"]},
       "participants":{"type":"array","items":{"type":"string"}},
       "utterances":{"type":"array","items":{
         "type":"object","additionalProperties":false,"required":["speaker","text"],
         "properties":{
           "speaker":{"type":"string"},
           "timestamp_seconds":{"type":["number","null"]},
           "text":{"type":"string"}}}}}}
    """

    private func aiResolve(_ raw: String) async throws -> ParsedTranscript {
        let json = try await llm.completeJSON(prompt: raw, system: Self.extractionSystem,
                                              schema: Self.extractionSchema)
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ParseError.decoding("AI import: model did not return valid JSON")
        }
        let rawUtts = (obj["utterances"] as? [[String: Any]]) ?? []
        var utterances: [ParsedUtterance] = []
        var speakers: [String] = []
        for (i, u) in rawUtts.enumerated() {
            let text = (u["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if text.isEmpty { continue }
            let speaker = (u["speaker"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Unknown"
            let ts = (u["timestamp_seconds"] as? Double) ?? (u["timestamp_seconds"] as? NSNumber)?.doubleValue
            if !speakers.contains(speaker) { speakers.append(speaker) }
            utterances.append(ParsedUtterance(
                seq: i, speakerRaw: speaker, speakerConfidence: 1.0,
                tStart: ts ?? 0, tEnd: ts ?? 0, text: text,
                isInferredSpeaker: false, tsConfidence: ts != nil ? .exact : .none))
        }
        guard !utterances.isEmpty else {
            throw ParseError.unrecognizedStructure("AI import: no utterances extracted")
        }
        let title = (obj["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        // Normalize to canonical YYYY-MM-DD (else date-gating's string compare silently excludes it —
        // Codex P4 gate MED). Reject anything we can't normalize rather than store garbage.
        let date = (obj["date"] as? String).flatMap { Self.normalizeDate($0) }
        return ParsedTranscript(title: (title?.isEmpty == false) ? title : "Imported call",
                                date: date, startedAt: nil, durationSeconds: nil,
                                source: .paste, speakers: speakers, utterances: utterances)
    }

    /// Coerce a model-returned date string to canonical `YYYY-MM-DD`, or nil if it isn't a real date.
    /// Handles `2026-06-29`, `2026/06/29`, `06/29/2026`, `6/29/26`, and `Jun 29, 2026` (via GeminiNotesParser).
    static func normalizeDate(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil { return t }
        if let m = t.range(of: #"^(\d{4})[/-](\d{1,2})[/-](\d{1,2})"#, options: .regularExpression) {
            return ymd(String(t[m]), order: .ymd)
        }
        if let m = t.range(of: #"^(\d{1,2})[/-](\d{1,2})[/-](\d{2,4})"#, options: .regularExpression) {
            return ymd(String(t[m]), order: .mdy)
        }
        return GeminiNotesParser.parseDate(t)         // "Jun 29, 2026"
    }

    private enum DateOrder { case ymd, mdy }
    private static func ymd(_ s: String, order: DateOrder) -> String? {
        let parts = s.split { $0 == "/" || $0 == "-" }.compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        let y: Int, mo: Int, d: Int
        switch order {
        case .ymd: (y, mo, d) = (parts[0], parts[1], parts[2])
        case .mdy: (mo, d, y) = (parts[0], parts[1], parts[2] < 100 ? 2000 + parts[2] : parts[2])
        }
        guard (1...12).contains(mo), (1...31).contains(d), (1900...2200).contains(y) else { return nil }
        return String(format: "%04d-%02d-%02d", y, mo, d)
    }

    private func generateTitle(forSpeakers speakers: [String], sample: String) async throws -> String {
        let who = speakers.prefix(4).joined(separator: ", ")
        let snippet = String(sample.prefix(1200))
        let c = try await llm.complete(
            prompt: "Participants: \(who)\n\nTranscript excerpt:\n\(snippet)\n\nReturn ONLY a concise 4–8 word meeting title, no quotes.",
            system: "You write short, specific meeting titles. Output only the title.",
            model: "sonnet", timeout: 60)
        return c.text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"")))
    }
}
