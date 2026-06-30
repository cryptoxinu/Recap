import Foundation

/// Anti-hallucination eval harness (Phase 4). Runs questions through the real `AskEngine` and checks the
/// non-negotiable invariants: a no-evidence question REFUSES, an answered question cites only chunks that
/// actually exist (no fabricated citations), and a date-scoped answer NEVER cites a meeting outside its
/// window. Deterministic cases (refusals / empty-window gates) run with no LLM; grounded-answer cases
/// need a live provider (gated by the caller).
public struct EvalCase: Sendable, Equatable {
    public enum Expect: Sendable, Equatable {
        case refuses                      // status == .noSources
        case answers                      // status == .answered with ≥1 valid citation
        case dateScoped(label: String)    // the plan resolved this date window
        case citesOnlyMeetings([String])  // every citation belongs to one of these meeting ids
    }
    public let id: String
    public let question: String
    public let now: Date?
    public let expects: [Expect]
    public init(id: String, question: String, now: Date? = nil, expects: [Expect]) {
        self.id = id; self.question = question; self.now = now; self.expects = expects
    }
}

public struct EvalResult: Sendable, Equatable {
    public let id: String
    public let passed: Bool
    public let status: String
    public let failures: [String]
}

public struct EvalHarness: Sendable {
    public let ask: AskEngine
    public init(ask: AskEngine) { self.ask = ask }

    public func run(_ cases: [EvalCase]) async -> [EvalResult] {
        var out: [EvalResult] = []
        for c in cases { out.append(await runOne(c)) }
        return out
    }

    private func runOne(_ c: EvalCase) async -> EvalResult {
        let ans: AskEngine.Answer
        do { ans = try await ask.ask(c.question, now: c.now ?? Date()) }
        catch { return EvalResult(id: c.id, passed: false, status: "error", failures: ["threw: \(error)"]) }

        var failures: [String] = []
        for e in c.expects {
            switch e {
            case .refuses:
                if ans.status != .noSources { failures.append("expected refusal, got answered") }
            case .answers:
                if ans.status != .answered { failures.append("expected answer, got \(ans.status.rawValue)") }
                else if ans.citations.isEmpty { failures.append("answered with no citations") }
                else {
                    // Grounding: every cited chunk must exist in the store (no fabricated id).
                    let ids = ans.citations.map(\.chunkID)
                    let real = Set(((try? ask.search.store.chunks(ids: ids)) ?? []).map(\.chunkID))
                    let ghost = ids.filter { !real.contains($0) }
                    if !ghost.isEmpty { failures.append("fabricated citation(s): \(ghost)") }
                }
            case .dateScoped(let label):
                if ans.plan?.dateRange?.label != label {
                    failures.append("expected date window '\(label)', got '\(ans.plan?.dateRange?.label ?? "none")'")
                }
            case .citesOnlyMeetings(let allowed):
                let allowedSet = Set(allowed)
                let outside = ans.citations.map(\.meetingID).filter { !allowedSet.contains($0) }
                if !outside.isEmpty { failures.append("cited out-of-scope meeting(s): \(Set(outside))") }
            }
        }
        return EvalResult(id: c.id, passed: failures.isEmpty, status: ans.status.rawValue, failures: failures)
    }
}

public extension Array where Element == EvalResult {
    var allPassed: Bool { allSatisfy(\.passed) }
    var report: String {
        let pass = filter(\.passed).count
        let lines = map { "\($0.passed ? "✓" : "✗") \($0.id) [\($0.status)]\($0.failures.isEmpty ? "" : " — " + $0.failures.joined(separator: "; "))" }
        return "Eval: \(pass)/\(count) passed\n" + lines.joined(separator: "\n")
    }
}
