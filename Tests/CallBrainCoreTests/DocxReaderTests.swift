import Testing
import Foundation
import ZIPFoundation
@testable import CallBrainCore

@Suite("DocxReader (native .docx text extraction)")
struct DocxReaderTests {

    // The real Google Meet "Notes by Gemini" export the founder dropped in.
    private static let realDocx =
        "/Users/z/CallBrain/data/raw/google_meet_recordings/morning sync - 2026_06_29 09_29 PDT - Notes by Gemini (1).docx"

    /// Pure XML → text extraction (no zip): the core logic, fully deterministic.
    @Test("extractText: runs joined, headings prefixed, junk skipped, entities unescaped")
    func extractTextCore() {
        let xml = """
        <w:body>
        <w:p><w:pPr><w:b w:val="1"/></w:pPr><w:r><w:t xml:space="preserve">Community and analytics</w:t></w:r></w:p>
        <w:p><w:r><w:t>Travis said Render </w:t></w:r><w:r><w:t>spot pricing dropped &amp; stabilized.</w:t></w:r></w:p>
        <w:p><w:r><w:t xml:space="preserve">✍️ Quick Notes</w:t></w:r></w:p>
        <w:p><w:r><w:t>• [Zade] Ship the importer</w:t></w:r></w:p>
        <w:p></w:p>
        """
        let out = DocxReader.extractText(xml)
        let lines = out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        #expect(lines.contains("## Community and analytics"))                       // bold short → heading
        #expect(lines.contains("Travis said Render spot pricing dropped & stabilized.")) // runs joined + &amp; unescaped
        #expect(!out.contains("✍️"))                                                // pen-emoji line dropped
        #expect(lines.contains("• [Zade] Ship the importer"))                       // bullet stays, NOT a heading
        let hasEmptyLine = lines.contains(where: { $0.isEmpty })
        #expect(!hasEmptyLine)                                                       // empty paragraph dropped
    }

    @Test("a bold but long paragraph is body text, not a heading")
    func longBoldIsNotHeading() {
        let long = String(repeating: "x", count: 80)
        let xml = "<w:p><w:pPr><w:b w:val=\"1\"/></w:pPr><w:r><w:t>\(long)</w:t></w:r></w:p>"
        #expect(DocxReader.extractText(xml) == long)   // no "## " prefix
    }

    @Test("prose containing the literal escaped text \"&lt;w:\" is NOT dropped (audit M2)")
    func escapedMarkupInProseKept() {
        // The run text is `if a &lt;w:foo then bail` (escaped) → unescapes to `if a <w:foo then bail`.
        // The old guard checked the UNESCAPED line for "<w:" and wrongly dropped it.
        let xml = "<w:p><w:r><w:t>if a &lt;w:foo then bail</w:t></w:r></w:p>"
        #expect(DocxReader.extractText(xml) == "if a <w:foo then bail")
    }

    /// Round-trip: build a real .docx zip in memory, read it back through the public API.
    @Test("read(): extracts word/document.xml from a real zip container")
    func readRoundTrip() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cb-docx-\(UUID().uuidString).docx")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let archive = try Archive(url: tmp, accessMode: .create)
        let xml = #"<?xml version="1.0"?><w:document><w:body>"#
            + #"<w:p><w:pPr><w:b w:val="1"/></w:pPr><w:r><w:t>Heading</w:t></w:r></w:p>"#
            + #"<w:p><w:r><w:t>Body line one.</w:t></w:r></w:p>"#
            + "</w:body></w:document>"
        let data = Data(xml.utf8)
        try archive.addEntry(with: "word/document.xml", type: .file,
                             uncompressedSize: Int64(data.count)) { pos, size in
            data.subdata(in: Int(pos)..<Int(pos) + size)
        }

        let text = try DocxReader.read(url: tmp)
        #expect(text == "## Heading\nBody line one.")
    }

    @Test("read(): a non-zip file throws notADocx")
    func nonZipThrows() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cb-notdocx-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try "just text, not a zip".write(to: tmp, atomically: true, encoding: .utf8)

        #expect(throws: DocxError.self) { _ = try DocxReader.read(url: tmp) }
    }

    /// Real-file smoke test — only runs when the founder's actual export is present.
    @Test("LIVE: reads the real morning-sync Gemini .docx into clean notes",
          .enabled(if: FileManager.default.fileExists(atPath: DocxReaderTests.realDocx)))
    func liveRealDocx() throws {
        let text = try DocxReader.read(url: URL(fileURLWithPath: Self.realDocx))
        #expect(!text.isEmpty)
        #expect(!text.contains("<w:"))                 // no XML leaked through
        #expect(!text.contains("✍️"))                  // pen-emoji header dropped
        #expect(text.contains("morning sync"))         // title survived
        #expect(text.lowercased().contains("render") || text.lowercased().contains("bitrouter"))
        print("LIVE DOCX (\(text.count) chars):\n\(text.prefix(1200))\n…")
    }
}
