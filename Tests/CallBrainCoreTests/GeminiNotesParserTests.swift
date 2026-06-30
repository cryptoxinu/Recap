import Testing
import Foundation
@testable import CallBrainCore

@Suite("Gemini Notes parser (Google Meet summary)")
struct GeminiNotesParserTests {

    static let sample = """
    morning sync
    ## Next steps
    - [Zade Kal] Discord API: Use official interface to perform content scraping.
    - [The group] Billing System: Develop estimate endpoint and document billing.
    ## Revenue and billing
    - Significant challenges persist in mapping GPU costs to individual request earnings.
    <w:rPr>leaked xml should be dropped</w:rPr>
    """

    @Test("parses notes into searchable lines with NO fabricated timestamps")
    func parses() throws {
        let t = try GeminiNotesParser.parse(Self.sample, title: "morning sync", date: "2026-06-29")
        #expect(t.source == .gmeetGemini)
        #expect(t.title == "morning sync")
        #expect(t.date == "2026-06-29")
        #expect(t.utterances.allSatisfy { $0.tsConfidence == .none })   // summary → no per-line timestamp
        #expect(t.utterances.allSatisfy { $0.speakerRaw == "Gemini Notes" })
        #expect(t.utterances.contains { $0.text.contains("Discord API") })
        #expect(!t.utterances.contains { $0.text.contains("<w:") })     // leaked XML dropped
    }

    @Test("parseDate handles 'Jun 29, 2026' style")
    func dates() {
        #expect(GeminiNotesParser.parseDate("Jun 29, 2026") == "2026-06-29")
        #expect(GeminiNotesParser.parseDate("June 1, 2025") == "2025-06-01")
        #expect(GeminiNotesParser.parseDate("not a date") == nil)
    }

    @Test("empty throws .empty")
    func empty() {
        #expect(throws: ParseError.empty) { try GeminiNotesParser.parse("   ", title: nil, date: nil) }
    }
}
