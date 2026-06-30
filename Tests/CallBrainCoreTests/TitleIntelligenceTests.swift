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
        let r = await TitleIntelligence(llm: llm).generate(from: "Zade: BitRouter is live now.", fallbackTitle: "morning sync")
        #expect(r?.title == "Ambient Morning Sync")
        #expect(r?.summary == "BitRouter live, Pearl GPU scaling")
        #expect(await TitleIntelligence(llm: llm).generate(from: "   \n ", fallbackTitle: "x") == nil)
    }

    @Test("empty title in the model output → nil (keep the existing title)")
    func emptyTitle() async {
        let llm = StubLLM(#"{"title":"  ","summary":"stuff"}"#)
        #expect(await TitleIntelligence(llm: llm).generate(from: "real content here", fallbackTitle: "keep") == nil)
    }
}
