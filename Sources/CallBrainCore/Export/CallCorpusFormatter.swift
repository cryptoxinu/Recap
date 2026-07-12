import Foundation
import CryptoKit

/// Pure serialization for the Call Corpus (Part B): turns a `CorpusCall` into the clean, LLM-readable
/// Markdown, the parallel structured JSON, the `index.jsonl` line, and the stable content hash + filename.
/// No I/O — deterministic given the same input + `exportedAt`, so it's fully golden-testable. This is the
/// generalized, richer descendant of `MeetingDetailView.recapMarkdown()`.
public enum CallCorpusFormatter {

    // MARK: Filenames

    /// A deterministic, filesystem-safe slug from a title: ASCII-folded, lowercased, non-alphanumerics
    /// collapsed to single dashes, capped at 60 chars. Falls back to "call" when nothing survives
    /// (emoji/CJK-only titles), so a file is always nameable.
    public static func slug(_ title: String) -> String {
        let folded = title.folding(options: [.diacriticInsensitive], locale: nil).lowercased()
        var out = ""
        var lastDash = false
        for scalar in folded.unicodeScalars {
            if (scalar >= "a" && scalar <= "z") || (scalar >= "0" && scalar <= "9") {
                out.unicodeScalars.append(scalar)
                lastDash = false
            } else if !out.isEmpty && !lastDash {
                out.append("-")
                lastDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        if out.count > 60 {
            out = String(out.prefix(60))
            while out.hasSuffix("-") { out.removeLast() }
        }
        return out.isEmpty ? "call" : out
    }

    /// `<date>-<slug>-<idHash>` — the stable per-call file stem. The suffix is 16 hex (64 bits) of
    /// SHA-256(id), a DETERMINISTIC per-id fragment; at 64 bits a collision needs ~billions of calls, so
    /// two calls effectively never share a filename. The write layer (CorpusExportService) additionally
    /// GUARANTEES uniqueness by disambiguating the astronomically-rare case where two distinct ids collide.
    /// `date` is sanitized to digits/dash so a malformed value can't inject a path separator; identity is
    /// always the id in frontmatter.
    public static func filenameStem(date: String, title: String, id: String) -> String {
        let safeDate = String(date.unicodeScalars.filter { ($0 >= "0" && $0 <= "9") || $0 == "-" })
        let datePart = safeDate.isEmpty ? "undated" : safeDate
        let idHash = SHA256.hash(data: Data(id.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return "\(datePart)-\(slug(title))-\(idHash)"
    }

    /// Seconds → "mm:ss" (or "h:mm:ss" past an hour). nil / non-finite (NaN/±inf) / negative → "00:00"; a
    /// pathological huge value is clamped so the `Int` conversion can never trap.
    public static func mmss(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds > 0 else { return "00:00" }
        let total = Int(min(seconds, 3_600_000).rounded(.down)) // cap at 1000h — beyond any real call
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    // MARK: Content hash (identity of the exported content, stable across re-runs)

    /// SHA-256 (hex) of the canonical JSON with `exported_at` excluded — so a re-export that changes
    /// nothing produces the same hash. This is what the ledger compares to skip / self-heal files.
    public static func exportHash(_ call: CorpusCall) -> String {
        SHA256.hash(data: canonicalJSONForHash(call)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: JSON

    /// The parallel `.json` artifact (pretty, key-sorted) with `exported_at` set — what a bot ingests.
    public static func json(_ call: CorpusCall, exportedAt: Date) -> Data {
        encode(dto(call, exportedAt: iso(exportedAt)), pretty: true)
    }

    /// The canonical form used ONLY for `exportHash` — key-sorted, compact, `exported_at` omitted.
    public static func canonicalJSONForHash(_ call: CorpusCall) -> Data {
        encode(dto(call, exportedAt: nil), pretty: false)
    }

    // MARK: index.jsonl

    public static func indexEntry(_ call: CorpusCall, stem: String, exportedAt: Date,
                                  exportHash: String) -> CorpusIndexEntry {
        CorpusIndexEntry(id: call.id, file: "calls/\(stem).md", json: "calls/\(stem).json",
                         date: call.date, title: call.title, source: call.source, company: call.company,
                         category: call.category, participants: call.participants,
                         durationSeconds: call.durationSeconds, actionItemCount: call.actionItems.count,
                         oneLiner: call.oneLiner, contentHash: call.contentHash, updatedAt: call.updatedAt,
                         exportHash: exportHash, exportedAt: iso(exportedAt))
    }

    /// One compact JSON line for `index.jsonl` (snake_case keys, sorted).
    public static func indexLine(_ entry: CorpusIndexEntry) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        enc.keyEncodingStrategy = .convertToSnakeCase
        guard let data = try? enc.encode(entry), let line = String(data: data, encoding: .utf8) else { return "" }
        return line
    }

    /// Parse an `index.jsonl` line back into an entry (loading the ledger). Returns nil on a bad line.
    public static func parseIndexLine(_ line: String) -> CorpusIndexEntry? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase
        return try? dec.decode(CorpusIndexEntry.self, from: data)
    }

    // MARK: Markdown

    /// The `.md` artifact: YAML frontmatter (everything filterable) + body (one-liner → notes → summary →
    /// action items → transcript). An LLM reads this top-down to understand the whole call.
    public static func markdown(_ call: CorpusCall, exportedAt: Date, exportHash: String) -> String {
        var fm = "---\n"
        fm += "schema_version: 1\n"
        fm += "id: \(oneLine(call.id))\n"
        fm += "title: \(yaml(call.title))\n"
        if let original = call.originalTitle, original != call.title {
            fm += "original_title: \(yaml(original))\n"
        }
        fm += "date: \(oneLine(call.date))\n"
        if let start = call.startTime { fm += "start_time: \(yaml(start))\n" }
        if let dur = call.durationSeconds {
            fm += "duration: \(yaml(mmss(Double(dur))))\n"
            fm += "duration_seconds: \(dur)\n"
        }
        fm += "source: \(yaml(call.source))\n"
        if let company = call.company { fm += "company: \(yaml(company))\n" }
        if let category = call.category { fm += "category: \(yaml(category))\n" }
        if let confidence = call.categoryConfidence, confidence.isFinite {
            fm += "category_confidence: \(String(format: "%.2f", confidence))\n"
        }
        if let summarySource = call.summarySource { fm += "summary_source: \(yaml(summarySource))\n" }
        if !call.participants.isEmpty {
            fm += "participants:\n"
            for participant in call.participants { fm += "  - \(yaml(participant))\n" }
        }
        if !call.actionItems.isEmpty {
            fm += "action_items:\n"
            for item in call.actionItems {
                fm += "  - owner: \(item.owner.map(yaml) ?? "null")\n"
                fm += "    text: \(yaml(item.text))\n"
                fm += "    status: \(yaml(item.status))\n"
            }
        }
        if let hash = call.contentHash { fm += "content_hash: \(yaml(hash))\n" }
        fm += "export_hash: \(oneLine(exportHash))\n"
        fm += "exported_at: \(iso(exportedAt))\n"
        fm += "---\n\n"

        var body = "# \(oneLine(call.title))\n"
        if let oneLiner = nonEmpty(call.oneLiner) { body += "\n> \(oneLine(oneLiner))\n" }
        if let notes = nonEmpty(call.userNotes) {
            body += "\n## Notes\n_Your own notes, typed during the call._\n\n\(notes)\n"
        }
        if let summary = nonEmpty(call.summary) {
            body += "\n## Summary\n\n\(summary)\n"
        }
        if !call.actionItems.isEmpty {
            body += "\n## Action items\n"
            for item in call.actionItems {
                let box = item.status == "done" ? "x" : " "
                if let owner = nonEmpty(item.owner) {
                    body += "- [\(box)] **\(oneLine(owner))**: \(oneLine(item.text))\n"
                } else {
                    body += "- [\(box)] \(oneLine(item.text))\n"
                }
            }
        }
        if !call.transcript.isEmpty {
            let speakers = Set(call.transcript.compactMap { turn -> String? in
                guard let s = turn.speaker?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
                return s
            })
            var meta = "source: \(oneLine(call.source))"
            if !speakers.isEmpty { meta += " · \(speakers.count) speaker\(speakers.count == 1 ? "" : "s")" }
            if let dur = call.durationSeconds { meta += " · \(mmss(Double(dur)))" }
            body += "\n## Transcript\n_\(meta)_\n\n"
            for turn in call.transcript {
                let tag = "[\(mmss(turn.t))]"
                let inferred = turn.inferred ? " _(inferred)_" : ""
                // Keep each turn on one line so a spoken line can't inject fake markdown headings/lists.
                let text = oneLine(turn.text)
                if let speaker = nonEmpty(turn.speaker) {
                    body += "**\(tag) \(oneLine(speaker).trimmingCharacters(in: .whitespaces)):**\(inferred) \(text)\n\n"
                } else {
                    body += "**\(tag)**\(inferred) \(text)\n\n"
                }
            }
        }
        return fm + body
    }

    // MARK: - Internals

    private struct CallDTO: Encodable {
        let schema_version = 1
        let id: String
        let title: String
        let original_title: String?
        let date: String
        let start_time: String?
        let duration_seconds: Int?
        let source: String
        let company: String?
        let category: String?
        let category_confidence: Double?
        let summary_source: String?
        let participants: [String]
        let one_liner: String?
        let user_notes: String?
        let summary: String?
        let action_items: [CorpusActionItem]
        let transcript: [TurnDTO]
        let content_hash: String?
        let exported_at: String?

        struct TurnDTO: Encodable {
            let t: Double?
            let t_mmss: String
            let speaker: String?
            let inferred: Bool
            let text: String
        }
    }

    private static func dto(_ call: CorpusCall, exportedAt: String?) -> CallDTO {
        CallDTO(id: call.id, title: call.title,
                original_title: (call.originalTitle != call.title) ? call.originalTitle : nil,
                date: call.date, start_time: call.startTime, duration_seconds: call.durationSeconds,
                source: call.source, company: call.company, category: call.category,
                category_confidence: finite(call.categoryConfidence), summary_source: call.summarySource,
                participants: call.participants, one_liner: call.oneLiner, user_notes: call.userNotes,
                summary: call.summary, action_items: call.actionItems,
                transcript: call.transcript.map {
                    CallDTO.TurnDTO(t: finite($0.t), t_mmss: mmss($0.t), speaker: $0.speaker,
                                    inferred: $0.inferred, text: $0.text)
                },
                content_hash: call.contentHash, exported_at: exportedAt)
    }

    private static func encode<T: Encodable>(_ value: T, pretty: Bool) -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = pretty
            ? [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
            : [.sortedKeys, .withoutEscapingSlashes]
        // Non-finite doubles are already sanitized to nil in `dto`; this is a belt-and-suspenders so a
        // future non-finite field can never make encode THROW → emit empty Data → collide export hashes.
        enc.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        if let data = try? enc.encode(value) { return data }
        assertionFailure("CallCorpusFormatter: JSON encode failed unexpectedly")
        return Data()
    }

    /// Only finite doubles reach JSON — NaN/±inf become nil (omitted), never a throw or a bogus number.
    private static func finite(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return value
    }

    /// ISO8601 in UTC (e.g. "2026-07-02T09:14:33Z") — deterministic regardless of machine timezone, so
    /// goldens are stable and the corpus reads the same everywhere. Built per call (export is not a hot
    /// path) to stay clear of shared-mutable-state under Swift 6 strict concurrency.
    private static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    /// A YAML double-quoted scalar. Sanitizes control characters + Unicode line/paragraph separators
    /// (U+2028/U+2029) to spaces FIRST — some YAML parsers treat those as line breaks — then escapes
    /// backslash and quote, so an arbitrary title/name/transcript value can never break out of the scalar
    /// or inject a frontmatter key.
    private static func yaml(_ value: String) -> String {
        let sanitized = String(String.UnicodeScalarView(value.unicodeScalars.map { scalar -> Unicode.Scalar in
            if scalar.value == 0x2028 || scalar.value == 0x2029 { return " " } // line / paragraph separator
            if scalar.value < 0x20 { return " " }                              // C0 controls incl. CR/LF/TAB
            if scalar.value >= 0x7F && scalar.value <= 0x9F { return " " }      // DEL + C1 controls (incl. NEL U+0085)
            return scalar
        }))
        let escaped = sanitized
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// Strip line breaks from an UNQUOTED frontmatter scalar (id, date, export_hash) or a body line, so a
    /// corrupted value can never inject a new frontmatter key / markdown block. Normal values are unchanged.
    private static func oneLine(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\u{0085}", with: " ") // NEL
            .replacingOccurrences(of: "\u{2028}", with: " ")
            .replacingOccurrences(of: "\u{2029}", with: " ")
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }
}
