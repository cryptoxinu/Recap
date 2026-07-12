import Testing
import Foundation
@testable import CallBrainCore

@Suite("TitleIntelligence")
struct TitleIntelligenceTests {
    /// Returns a fixed JSON for `completeJSON` (no network).
    final class StubLLM: LLMProvider, @unchecked Sendable {
        let json: String
        nonisolated var id: ProviderID { .claude }
        init(_ json: String) { self.json = json }
        func complete(prompt: String, system: String?, model: String, timeout: TimeInterval) async throws -> Completion {
            Completion(text: json, provider: .claude, model: model, usage: TokenUsage(), costUSD: 0)
        }
        func completeJSON(prompt: String, system: String?, schema: String, model: String, timeout: TimeInterval) async throws -> String { json }
    }

    @Test("parses title + summary; refuses empty content")
    func generate() async {
        let llm = StubLLM(#"{"title":"Ambient Morning Sync","summary":"BitRouter live, Pearl GPU scaling"}"#)
        let r = await TitleIntelligence(llm: llm).generate(from: "Alex: BitRouter is live now.", fallbackTitle: "morning sync")
        #expect(r?.title == "Ambient Morning Sync")
        #expect(r?.summary == "BitRouter live, Pearl GPU scaling")
        #expect(await TitleIntelligence(llm: llm).generate(from: "   \n ", fallbackTitle: "x") == nil)
    }

    @Test("empty title in the model output → nil (keep the existing title)")
    func emptyTitle() async {
        let llm = StubLLM(#"{"title":"  ","summary":"stuff"}"#)
        #expect(await TitleIntelligence(llm: llm).generate(from: "real content here", fallbackTitle: "keep") == nil)
    }

    @Test("a NON-EMPTY but invalid title falls back to the caller's title; the summary survives (B11)")
    func invalidTitleFallsBack() async {
        // A run-on 'title' (a whole sentence) is invalid → use the fallback, keep the summary.
        let junk = #"{"title":"We discussed a whole lot of things across many different topics today","summary":"good summary"}"#
        let r = await TitleIntelligence(llm: StubLLM(junk)).generate(from: "real content", fallbackTitle: "Morning Sync")
        #expect(r?.title == "Morning Sync")
        #expect(r?.summary == "good summary")
    }

    @Test("validate strips quotes, rejects run-ons / bare dates / generic single words")
    func validate() {
        #expect(TitleIntelligence.validate("\"Ambient Morning Sync\"") == "Ambient Morning Sync")
        #expect(TitleIntelligence.validate("2026-06-29 daily standup notes") == nil)   // bare date
        #expect(TitleIntelligence.validate("Meeting") == nil)                          // generic
        #expect(TitleIntelligence.validate("one two three four five six seven eight nine") == nil)  // run-on
    }
}
