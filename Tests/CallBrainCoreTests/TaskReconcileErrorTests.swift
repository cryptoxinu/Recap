import Testing
import Foundation
@testable import CallBrainCore

/// The "Tidy never worked" root cause was that `reconcile` swallowed every failure with `try?` → silent
/// nil → the generic "Couldn't reach the AI" banner, hiding a rate-limit (2026-07-11). These lock in that
/// `reconcileThrowing` now SURFACES the real cause so the UI can show a specific, actionable message.
@Suite("Tidy reconcile error propagation")
struct TaskReconcileErrorTests {
    struct StubLLM: LLMProvider {
        let id: ProviderID = .claude
        let jsonResult: Result<String, LLMError>
        func complete(prompt: String, system: String?, model: String, timeout: TimeInterval) async throws -> Completion {
            throw LLMError.notInstalled("stub has no complete()")
        }
        func completeJSON(prompt: String, system: String?, schema: String, model: String, timeout: TimeInterval) async throws -> String {
            try jsonResult.get()
        }
        func streamComplete(prompt: String, system: String?, model: String, timeout: TimeInterval) -> AsyncThrowingStream<StreamEvent, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }
    let task = TaskIntelligence.TaskContext(id: "t1", owner: "Sam", text: "send the deck", meeting: "Sync")

    @Test("a rate-limit propagates (no longer hidden behind a silent nil)")
    func propagatesRateLimit() async {
        let ti = TaskIntelligence(llm: StubLLM(jsonResult: .failure(.rateLimited(resetAt: nil))))
        do {
            _ = try await ti.reconcileThrowing(tasks: [task], evidence: "call content")
            Issue.record("expected a throw")
        } catch let e as LLMError { #expect(e == .rateLimited(resetAt: nil)) }
        catch { Issue.record("wrong error type: \(error)") }
    }

    @Test("allProvidersFailed(rateLimited) propagates — this is the exact real-world failure")
    func propagatesAllProvidersFailed() async {
        let ti = TaskIntelligence(llm: StubLLM(jsonResult: .failure(.allProvidersFailed("rateLimited(resetAt: nil)"))))
        do {
            _ = try await ti.reconcileThrowing(tasks: [task], evidence: "call content")
            Issue.record("expected a throw")
        } catch let e as LLMError {
            if case .allProvidersFailed = e {} else { Issue.record("wrong case: \(e)") }
        } catch { Issue.record("wrong error type: \(error)") }
    }

    @Test("a not-installed CLI propagates")
    func propagatesNotInstalled() async {
        let ti = TaskIntelligence(llm: StubLLM(jsonResult: .failure(.notInstalled("~/.local/bin/claude"))))
        do { _ = try await ti.reconcileThrowing(tasks: [task], evidence: "x"); Issue.record("expected a throw") }
        catch let e as LLMError { if case .notInstalled = e {} else { Issue.record("wrong case: \(e)") } }
        catch { Issue.record("wrong error type: \(error)") }
    }

    @Test("malformed JSON surfaces as a decode error, not a plausible-looking empty plan")
    func decodeFailureSurfaces() async {
        let ti = TaskIntelligence(llm: StubLLM(jsonResult: .success("not json at all")))
        do { _ = try await ti.reconcileThrowing(tasks: [task], evidence: "x"); Issue.record("expected a throw") }
        catch let e as LLMError { if case .decodeFailed = e {} else { Issue.record("wrong case: \(e)") } }
        catch { Issue.record("wrong error type: \(error)") }
    }

    @Test("a valid empty plan decodes to an empty (no-op) Plan")
    func validEmptyPlan() async throws {
        let ti = TaskIntelligence(llm: StubLLM(jsonResult: .success(#"{"reword":[],"complete":[],"duplicates":[],"add":[]}"#)))
        let plan = try await ti.reconcileThrowing(tasks: [task], evidence: "x")
        #expect(plan?.reword.isEmpty == true && plan?.complete.isEmpty == true
                && plan?.duplicates.isEmpty == true && plan?.add.isEmpty == true)
    }

    @Test("nothing to do (no tasks + no evidence) returns nil without calling the AI")
    func nothingToDo() async throws {
        let ti = TaskIntelligence(llm: StubLLM(jsonResult: .failure(.rateLimited(resetAt: nil))))  // would throw if called
        let plan = try await ti.reconcileThrowing(tasks: [], evidence: "")
        #expect(plan == nil)
    }
}
