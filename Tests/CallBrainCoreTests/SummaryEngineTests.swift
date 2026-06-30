import Testing
import Foundation
@testable import CallBrainCore

@Suite("SummaryEngine (local + cloud call summaries)")
struct SummaryEngineTests {
    final class StubLLM: LLMProvider, @unchecked Sendable {
        let json: String
        nonisolated var id: ProviderID { .claude }
        init(_ json: String) { self.json = json }
        func complete(prompt: String, system: String?, model: String, timeout: TimeInterval) async throws -> Completion {
            Completion(text: json, provider: .claude, model: model, usage: TokenUsage(), costUSD: 0)
        }
        func completeJSON(prompt: String, system: String?, schema: String, model: String, timeout: TimeInterval) async throws -> String { json }
    }

    @Test("parses a well-formed summary + action items")
    func parseGood() {
        let json = #"""
        {"summary":"**TL;DR:** synced.\n\n## Decisions\n- **Ship** Friday",
         "action_items":[{"owner":"Zade","text":"Fix BitRouter format"},{"owner":null,"text":"Email the deck"}]}
        """#
        let s = SummaryPrompt.parse(json, source: "local")
        #expect(s != nil)
        #expect(s?.source == "local")
        #expect(s?.summary.contains("## Decisions") == true)
        #expect(s?.actionItems.count == 2)
        #expect(s?.actionItems.first?.owner == "Zade")
        #expect(s?.actionItems.last?.owner == nil)   // null owner is allowed
    }

    @Test("missing/empty summary → nil (caller falls back)")
    func parseEmpty() {
        #expect(SummaryPrompt.parse(#"{"summary":"   ","action_items":[]}"#, source: "local") == nil)
        #expect(SummaryPrompt.parse("not json at all", source: "local") == nil)
        #expect(SummaryPrompt.parse(#"{"action_items":[]}"#, source: "local") == nil)
    }

    @Test("absent action_items decodes to an empty list, not a failure")
    func parseNoItems() {
        let json = #"""
        {"summary":"## Recap\n- done"}
        """#
        let s = SummaryPrompt.parse(json, source: "cloud")
        #expect(s != nil)
        #expect(s?.actionItems.isEmpty == true)
    }

    @Test("schema is a valid JSON object usable as Ollama's grammar-constrained format")
    func schemaObject() {
        let obj = SummaryPrompt.schemaObject as? [String: Any]
        #expect(obj != nil)
        #expect(obj?["type"] as? String == "object")
        #expect(JSONSerialization.isValidJSONObject(obj as Any))
    }

    @Test("CLISummarizer maps the model's JSON into a cloud-sourced summary")
    func cliSummarizer() async {
        let json = #"""
        {"summary":"## Recap\n- shipped","action_items":[{"owner":"Ghazal","text":"Share doc"}]}
        """#
        let out = await CLISummarizer(llm: StubLLM(json), model: "opus").summarize(transcript: "…", title: "Sync")
        #expect(out?.source == "cloud")
        #expect(out?.actionItems.first?.text == "Share doc")
    }

    @Test("body caps very long transcripts so num_ctx is never blown")
    func bodyCaps() {
        let huge = String(repeating: "x", count: 80_000)
        let body = SummaryPrompt.body(transcript: huge, title: "T")
        #expect(body.count < 30_000)   // 24k transcript cap + small framing
    }
}
