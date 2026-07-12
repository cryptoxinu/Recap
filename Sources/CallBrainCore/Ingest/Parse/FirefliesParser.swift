import Foundation

/// Parses a Fireflies transcript export (the GraphQL/JSON shape with `sentences[]`) into the CTM.
///
/// Tolerant by design: we read fields out of a loosely-typed JSON object rather than matching a
/// rigid Codable shape, so unexpected extra fields or a nested `transcript` wrapper don't break it.
/// The only hard requirement is a non-empty `sentences[]` with usable text. Fireflies gives explicit
/// speaker labels + exact per-sentence timestamps → `tsConfidence = .exact`, `isInferredSpeaker = false`.
public enum FirefliesParser {

    public static func parse(_ data: Data) throws -> ParsedTranscript {
        guard !data.isEmpty else { throw ParseError.empty }

        let any: Any
        do { any = try JSONSerialization.jsonObject(with: data) }
        catch { throw ParseError.decoding("Fireflies: invalid JSON (\(error.localizedDescription))") }

        guard var root = any as? [String: Any] else {
            throw ParseError.unrecognizedStructure("Fireflies: top level is not a JSON object")
        }
        // Some exports nest the payload under "transcript".
        if let nested = root["transcript"] as? [String: Any] {
            root = root.merging(nested) { _, new in new }
        }

        guard let sentences = root["sentences"] as? [[String: Any]], !sentences.isEmpty else {
            throw ParseError.unrecognizedStructure("Fireflies: no sentences[] array")
        }

        var utterances: [ParsedUtterance] = []
        var speakerOrder: [String] = []
        utterances.reserveCapacity(sentences.count)

        for (i, s) in sentences.enumerated() {
            let text = ((s["text"] as? String) ?? (s["raw_text"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }

            let speaker: String = {
                if let n = s["speaker_name"] as? String, !n.isEmpty { return n }
                if let id = s["speaker_id"] { return "Speaker \(id)" }
                return "Unknown"
            }()

            let start = doubleValue(s["start_time"]) ?? 0
            let end = doubleValue(s["end_time"]) ?? start
            let idx = (s["index"] as? Int) ?? i

            if !speakerOrder.contains(speaker) { speakerOrder.append(speaker) }
            utterances.append(ParsedUtterance(
                seq: idx, speakerRaw: speaker, speakerConfidence: 1.0,
                tStart: start, tEnd: max(start, end), text: text,
                isInferredSpeaker: false, tsConfidence: .exact))
        }

        guard !utterances.isEmpty else {
            throw ParseError.unrecognizedStructure("Fireflies: sentences[] had no usable text")
        }

        let title = (root["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let (dateStr, startedAt) = resolveDate(root)
        let durationSec = doubleValue(root["duration"]).map { Int(($0 * 60).rounded()) } // Fireflies reports minutes

        return ParsedTranscript(
            title: (title?.isEmpty == false) ? title : nil,
            date: dateStr, startedAt: startedAt, durationSeconds: durationSec,
            source: .fireflies, speakers: speakerOrder, utterances: utterances)
    }

    // MARK: - helpers

    /// JSONSerialization yields NSNumber for numeric JSON; bridge it (or a String) to Double.
    private static func doubleValue(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }

    private static func resolveDate(_ root: [String: Any]) -> (String?, Date?) {
        // Fireflies `date` is epoch milliseconds.
        if let ms = doubleValue(root["date"]) {
            let d = Date(timeIntervalSince1970: ms / 1000.0)
            return (TimeCode.ymd(d), d)
        }
        if let ds = (root["dateString"] as? String) ?? (root["date"] as? String) {
            if let d = ISO8601DateFormatter().date(from: ds) { return (TimeCode.ymd(d), d) }
            if ds.count >= 10 { return (String(ds.prefix(10)), nil) }
        }
        return (nil, nil)
    }
}
