import Foundation

/// Parses a Fathom (free-tier) transcript **copy** (plain text) into the CTM.
///
/// Fathom free has no API/download, so the input is whatever the user copies. Tolerant/regex-based —
/// it recognizes two speaker-header forms and accumulates the following lines as that speaker's text:
///   • `Riley  0:00`            (name, then a timecode at end of line)
///   • `Riley (0:00): text…`    (name, parenthesized timecode, optional inline text)
/// A leading non-header line before any speaker is treated as the title. Fathom carries exact per-turn
/// timecodes (start only) → `tsConfidence = .exact`; each turn's `tEnd` is derived from the next turn's start.
public enum FathomParser {

    public static func parse(_ text: String) throws -> ParsedTranscript {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ParseError.empty
        }

        let lines = normalized.components(separatedBy: "\n")
        var utterances: [ParsedUtterance] = []
        var speakerOrder: [String] = []
        var title: String?
        var pendingSpeaker: String?
        var pendingStart: Double = 0
        var pendingText: [String] = []

        func flush() {
            guard let sp = pendingSpeaker else { pendingText = []; return }
            let body = pendingText.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            pendingText = []
            guard !body.isEmpty else { return }
            utterances.append(ParsedUtterance(
                seq: utterances.count, speakerRaw: sp, speakerConfidence: 1.0,
                tStart: pendingStart, tEnd: pendingStart, text: body,
                isInferredSpeaker: false, tsConfidence: .exact))
            if !speakerOrder.contains(sp) { speakerOrder.append(sp) }
        }

        for lineRaw in lines {
            let line = lineRaw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.lowercased().contains("fathom.video") && line.lowercased().hasPrefix("http") { continue }

            if let h = Self.header(in: lineRaw) {
                flush()
                pendingSpeaker = h.speaker
                pendingStart = h.start
                if let inline = h.inlineText, !inline.isEmpty { pendingText.append(inline) }
            } else if pendingSpeaker != nil {
                pendingText.append(line)
            } else if title == nil && utterances.isEmpty {
                title = line                           // first prose line before any speaker = title
            }
        }
        flush()

        guard !utterances.isEmpty else {
            throw ParseError.unrecognizedStructure("Fathom: no speaker/timecode blocks recognized")
        }

        // Fathom gives only a start per turn → derive tEnd from the next turn's start.
        for i in utterances.indices {
            utterances[i].tEnd = (i + 1 < utterances.count)
                ? max(utterances[i].tStart, utterances[i + 1].tStart)
                : utterances[i].tStart
        }

        return ParsedTranscript(
            title: title, date: nil, startedAt: nil, durationSeconds: nil,
            source: .fathom, speakers: speakerOrder, utterances: utterances)
    }

    // MARK: - header detection

    private struct Header { let speaker: String; let start: Double; let inlineText: String? }

    // Compile once (these literals are valid, so `try!` is safe).
    private static let inlineRE = try! NSRegularExpression(
        pattern: #"^\s*(.+?)\s*\((\d{1,2}:\d{2}(?::\d{2})?)\)\s*:?\s*(.*)$"#)
    private static let endRE = try! NSRegularExpression(
        pattern: #"^\s*(.+?)\s+(\d{1,2}:\d{2}(?::\d{2})?)\s*$"#)

    private static func header(in line: String) -> Header? {
        // Prefer the unambiguous parenthesized form.
        if let g = match(inlineRE, line), let t = TimeCode.seconds(from: g[2]),
           isPlausibleSpeaker(g[1]) {
            return Header(speaker: g[1].trimmingCharacters(in: .whitespaces), start: t,
                          inlineText: g.count > 3 ? g[3].trimmingCharacters(in: .whitespaces) : nil)
        }
        if let g = match(endRE, line), let t = TimeCode.seconds(from: g[2]),
           isPlausibleSpeaker(g[1]) {
            return Header(speaker: g[1].trimmingCharacters(in: .whitespaces), start: t, inlineText: nil)
        }
        return nil
    }

    /// Guard against a body line that merely ends in a timecode ("let's meet by 5:00") being mistaken
    /// for a speaker header: a real speaker label is short and free of sentence punctuation.
    private static func isPlausibleSpeaker(_ name: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, n.count <= 40 else { return false }
        if n.contains(where: { ".?!,;".contains($0) }) { return false }
        return n.split(separator: " ").count <= 4
    }

    private static func match(_ re: NSRegularExpression, _ line: String) -> [String]? {
        let ns = line as NSString
        guard let m = re.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            return r.location == NSNotFound ? "" : ns.substring(with: r)
        }
    }
}
