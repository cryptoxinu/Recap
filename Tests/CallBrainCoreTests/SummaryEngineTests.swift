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
         "action_items":[{"owner":"Alex","text":"Fix BitRouter format"},{"owner":null,"text":"Email the deck"}]}
        """#
        let s = SummaryPrompt.parse(json, source: "local")
        #expect(s != nil)
        #expect(s?.source == "local")
        #expect(s?.summary.contains("## Decisions") == true)
        #expect(s?.actionItems.count == 2)
        #expect(s?.actionItems.first?.owner == "Alex")
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
        {"summary":"## Recap\n- shipped","action_items":[{"owner":"Priya","text":"Share doc"}]}
        """#
        let out = await CLISummarizer(llm: StubLLM(json), model: "opus").summarize(transcript: "…", title: "Sync")
        #expect(out?.source == "cloud")
        #expect(out?.actionItems.first?.text == "Share doc")
    }

    @Test("body caps only when ASKED (local windows handle num_ctx; cloud runs uncapped — Task 6.7)")
    func bodyCaps() {
        let huge = String(repeating: "x", count: 80_000)
        #expect(SummaryPrompt.body(transcript: huge, title: "T", cap: 24_000).count < 30_000)
        #expect(SummaryPrompt.body(transcript: huge, title: "T").count > 79_000)   // uncapped by default
    }
}

/// Task 6.7 — long calls summarize their TAIL, not just their opening 24k chars.
@Suite("Summary windows (Task 6.7)")
struct SummaryWindowTests {
    @Test("windows split on line boundaries and always cover the tail")
    func testWindowsCoverTail() {
        let lines = (0..<3000).map { "Speaker \($0 % 4): line \($0) of the very long meeting transcript." }
        let transcript = lines.joined(separator: "\n")
        let windows = SummaryPrompt.windows(transcript, cap: 20_000)
        #expect(windows.count > 1)
        #expect(windows.joined(separator: "\n") == transcript)              // nothing lost
        #expect(windows.last!.contains("line 2999"))                        // the tail survives
        #expect(windows.allSatisfy { $0.count <= 20_000 + 200 })            // cap respected (± one line)
    }

    @Test("short transcripts stay single-window")
    func testShortSingleWindow() {
        #expect(SummaryPrompt.windows("short call", cap: 20_000) == ["short call"])
    }

    @Test("cloud body carries the FULL transcript (no 24k cap)")
    func testCloudBodyUncapped() {
        let long = String(repeating: "x", count: 30_000)
        #expect(SummaryPrompt.body(transcript: long, title: "t").count > 29_000)
    }
}
