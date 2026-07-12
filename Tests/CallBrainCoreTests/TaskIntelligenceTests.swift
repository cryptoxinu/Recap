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
        {"reword":[{"id":"t1","text":"Fix BitRouter reasoning format","owner":"Marco"}],
         "complete":["t2"],
         "duplicates":["t3"],
         "add":[{"meetingID":"m1","owner":"Alex","text":"Document billing request flow"}]}
        """#
        let ctx = [TaskIntelligence.TaskContext(id: "t1", owner: "Marco", text: "fix bitrouter", meeting: "sync")]
        let p = try #require(await TaskIntelligence(llm: StubLLM(json)).reconcile(tasks: ctx, evidence: "## CALL meetingID=m1\nstuff"))
        #expect(p.reword.first?.id == "t1" && p.reword.first?.text.contains("BitRouter") == true)
        #expect(p.complete == ["t2"])
        #expect(p.duplicates == ["t3"])
        #expect(p.add.first?.meetingID == "m1" && p.add.first?.owner == "Alex")
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

    @Test("isNearDuplicate catches a reworded restatement (so Tidy can't resurface a DONE task)")
    func nearDuplicate() {
        let done = ["Send Junney a full blurb on what Ambient AI does", "Review iOS app bugs this week"]
        #expect(TaskIntelligence.isNearDuplicate("Send Junney the blurb about Ambient", of: done))   // reworded → dup
        #expect(TaskIntelligence.isNearDuplicate("review the ios app bugs", of: done))
        #expect(!TaskIntelligence.isNearDuplicate("Book the Q3 offsite venue", of: done))             // unrelated → keep
    }
}

@Suite("FounderIdentity — the app is single-user (what is MINE)", .serialized)
struct FounderIdentityTests {
    @Test("mine = the founder, org-wide, or unassigned; NOT someone else")
    func isMine() {
        let aliases = ["alex", "sam", "alex king", "alex kingsley"]
        #expect(FounderIdentity.isMine("Alex", aliases: aliases))
        #expect(FounderIdentity.isMine("Sam", aliases: aliases))
        #expect(FounderIdentity.isMine("Alex King", aliases: aliases))          // token match
        #expect(FounderIdentity.isMine(nil, aliases: aliases))                 // unassigned -> mine
        #expect(FounderIdentity.isMine("  ", aliases: aliases))                // blank -> mine
        #expect(FounderIdentity.isMine("everyone", aliases: aliases))          // org-wide -> mine
        #expect(FounderIdentity.isMine("the team", aliases: aliases))
        #expect(!FounderIdentity.isMine("Robin", aliases: aliases))           // someone else -> not mine
        #expect(!FounderIdentity.isMine("Priya Kang", aliases: aliases))
    }

    @Test("custom names from Settings override the defaults")
    func customNames() {
        let aliases = ["bob", "robert"]
        #expect(FounderIdentity.isMine("Bob", aliases: aliases))
        #expect(!FounderIdentity.isMine("Alex", aliases: aliases))             // no longer a founder alias
    }
}
