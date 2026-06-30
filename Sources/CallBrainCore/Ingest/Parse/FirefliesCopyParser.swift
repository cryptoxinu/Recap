import Foundation

/// Parses a Fireflies transcript **copy** (the free-tier "copy" output — no JSON export available).
///
/// Real-world format (verified against an actual call): each turn is a header line
/// `Speaker Name: H:MM:SS` followed by the spoken text on the next line(s); turns are separated by
/// blank lines. Timestamps are `M:SS` or `H:MM:SS`. Fireflies gives explicit speaker labels + a
/// per-turn timestamp → `tsConfidence = .exact`, `isInferredSpeaker = false`. `tEnd` is derived from
/// the next turn's start (the copy carries only a start per turn).
public enum FirefliesCopyParser {

    private nonisolated(unsafe) static let headerRE = try! NSRegularExpression(
        pattern: #"^\s*(.+?):\s+(\d{1,2}:\d{2}(?::\d{2})?)\s*$"#)

    public static func parse(_ text: String) throws -> ParsedTranscript {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ParseError.empty }

        let lines = normalized.components(separatedBy: "\n")
        var utterances: [ParsedUtterance] = []
        var speakerOrder: [String] = []
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

        for line in lines {
            if let h = header(line) {
                flush()
                pendingSpeaker = h.speaker
                pendingStart = h.start
            } else {
                let t = line.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty, pendingSpeaker != nil { pendingText.append(t) }
            }
        }
        flush()

        guard !utterances.isEmpty else {
            throw ParseError.unrecognizedStructure("Fireflies copy: no 'Name: H:MM:SS' speaker headers found")
        }

        for i in utterances.indices {
            utterances[i].tEnd = (i + 1 < utterances.count)
                ? max(utterances[i].tStart, utterances[i + 1].tStart)
                : utterances[i].tStart
        }

        let durationSec = utterances.last.map { Int($0.tStart.rounded()) }
        return ParsedTranscript(
            title: nil, date: nil, startedAt: nil, durationSeconds: durationSec,
            source: .fireflies, speakers: speakerOrder, utterances: utterances)
    }

    private static func header(_ line: String) -> (speaker: String, start: Double)? {
        let ns = line as NSString
        guard let m = headerRE.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let name = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
        let ts = ns.substring(with: m.range(at: 2))
        guard isPlausibleSpeaker(name), let secs = TimeCode.seconds(from: ts) else { return nil }
        return (name, secs)
    }

    /// Guard so a body line that happens to contain "word: 1:23" isn't mistaken for a speaker header.
    private static func isPlausibleSpeaker(_ n: String) -> Bool {
        !n.isEmpty && n.count <= 40
            && n.split(separator: " ").count <= 5
            && !n.contains(where: { ".?!".contains($0) })
    }
}
