import Foundation
import ZIPFoundation

public enum DocxError: Error, Sendable, Equatable {
    case notADocx(String)
    case noDocumentXML
    case empty
    case tooLarge(mb: Int)        // document.xml inflates past the ceiling — zip-bomb / OOM guard
}

/// Native-Swift `.docx` text extraction (a `.docx` is a ZIP whose `word/document.xml` holds the body).
/// Used for Google Meet "Notes by Gemini" files so the app ingests them directly — no Python.
/// Bold short paragraphs are prefixed `## ` so GeminiNotesParser sees the section structure.
public enum DocxReader {
    /// Cap on the decompressed `document.xml` (a small .docx whose XML inflates to GBs is a zip bomb).
    static let maxDocumentBytes = 128 * 1024 * 1024

    public static func read(url: URL) throws -> String {
        let archive: Archive
        do { archive = try Archive(url: url, accessMode: .read) }
        catch { throw DocxError.notADocx(error.localizedDescription) }

        guard let entry = archive["word/document.xml"] else { throw DocxError.noDocumentXML }
        // Reject before inflating if the entry advertises an absurd uncompressed size (zip-bomb guard).
        if entry.uncompressedSize > Int64(maxDocumentBytes) {
            throw DocxError.tooLarge(mb: Int(entry.uncompressedSize / (1024 * 1024)))
        }
        var data = Data()
        _ = try archive.extract(entry) { chunk in
            data.append(chunk)
            // Belt-and-suspenders: also bound the actual inflated bytes (advertised size can lie).
            if data.count > maxDocumentBytes { throw DocxError.tooLarge(mb: data.count / (1024 * 1024)) }
        }

        let text = extractText(String(decoding: data, as: UTF8.self))
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DocxError.empty }
        return text
    }

    static func extractText(_ xml: String) -> String {
        var lines: [String] = []
        for para in xml.components(separatedBy: "</w:p>") {
            let runs = matches(in: para, pattern: #"<w:t[^>]*>(.*?)</w:t>"#)
            let joined = runs.joined()
            // Detect leaked markup on the RAW run output (before unescape) — checking the unescaped line
            // would wrongly drop real prose that contains the literal text "&lt;w:" (SME audit M2).
            if joined.contains("<w:") { continue }
            let line = unescape(joined).trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("✍️") { continue }
            lines.append(headingPrefix(forParagraph: para, line: line) + line)
        }
        return lines.joined(separator: "\n")
    }

    /// Markdown heading marker for a paragraph, or "" for body text. The reliable signal in a
    /// Google-Docs/Gemini export is the Word **paragraph style** (`Title`/`Subtitle`/`Heading2`…);
    /// a short bold non-bullet paragraph is the fallback for docs that carry no styles.
    private static func headingPrefix(forParagraph para: String, line: String) -> String {
        if let style = firstMatch(in: para, pattern: #"<w:pStyle w:val="([^"]+)"/>"#)?.lowercased() {
            if style.contains("subtitle") { return "## " }     // section header (check before "title")
            if style.contains("title") { return "## " }
            if style == "heading1" || style == "heading2" { return "## " }
            if style.hasPrefix("heading") { return "### " }    // heading3+ → sub-point
        }
        let bold = para.contains(#"<w:b w:val="1"/>"#) || para.contains("<w:b/>")
        if bold && line.count < 60 && !line.hasPrefix("•") && !line.hasPrefix("[") { return "## " }
        return ""
    }

    private static func matches(in s: String, pattern: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).compactMap {
            $0.range(at: 1).location == NSNotFound ? nil : ns.substring(with: $0.range(at: 1))
        }
    }

    private static func firstMatch(in s: String, pattern: String) -> String? {
        matches(in: s, pattern: pattern).first
    }

    private static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
    }
}
