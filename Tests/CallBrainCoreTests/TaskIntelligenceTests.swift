import Testing
import Foundation
@testable import CallBrainCore

@Suite("TaskIntelligence (AI task reconciliation)")
struct TaskIntelligenceTests {
    final class StubLLM: LLMProvider, @unchecked Sendable {
        let json: String
        nonisolated var id: ProviderID { .codex }
        init(_ json: String) { self.json = json }
        func complete(prompt: String, system: String?, model: String, timeout: TimeInterval) async throws -> Completion {
            Completion(text: json, provider: .codex, model: model, usage: TokenUsage(), costUSD: 0)
        }
        func completeJSON(prompt: String, system: String?, schema: String, model: String, timeout: TimeInterval) async throws -> String { json }
    }

    @Test("decodes a tidy plan: reword / complete / duplicates / add")
    func plan() async throws {
        let json = #"""
        {"reword":[{"id":"t1","text":"Fix BitRouter reasoning format","owner":"Gregory"}],
         "complete":["t2"],
         "duplicates":["t3"],
         "add":[{"meetingID":"m1","owner":"Zade","text":"Document billing request flow"}]}
        """#
        let ctx = [TaskIntelligence.TaskContext(id: "t1", owner: "Gregory", text: "fix bitrouter", meeting: "sync")]
        let p = try #require(await TaskIntelligence(llm: StubLLM(json)).reconcile(tasks: ctx, evidence: "## CALL meetingID=m1\nstuff"))
        #expect(p.reword.first?.id == "t1" && p.reword.first?.text.contains("BitRouter") == true)
        #expect(p.complete == ["t2"])
        #expect(p.duplicates == ["t3"])
        #expect(p.add.first?.meetingID == "m1" && p.add.first?.owner == "Zade")
    }

    @Test("empty arrays decode fine; nothing to do is valid")
    func emptyPlan() async {
        let p = await TaskIntelligence(llm: StubLLM(#"{"reword":[],"complete":[],"duplicates":[],"add":[]}"#))
            .reconcile(tasks: [TaskIntelligence.TaskContext(id: "x", owner: nil, text: "t", meeting: "m")], evidence: "e")
        #expect(p != nil && p!.reword.isEmpty && p!.add.isEmpty)
    }

    @Test("no tasks AND no evidence → nil (nothing to reconcile)")
    func nothing() async {
        #expect(await TaskIntelligence(llm: StubLLM("{}")).reconcile(tasks: [], evidence: "") == nil)
    }
}
