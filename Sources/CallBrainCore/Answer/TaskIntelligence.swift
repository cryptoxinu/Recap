import Foundation

/// "Higher-intelligence layer for tasks" (founder ask 2026-06-30): one LLM pass over the current OPEN
/// tasks + the content of every call that (a) rewords tasks more clearly, (b) marks tasks the calls show
/// are already done, (c) merges duplicates, and (d) adds tasks the calls state but the list missed.
/// Grounded — it only acts on what the evidence supports; the app never hard-deletes (completion/dedup
/// just mark Done, which is reversible).
public struct TaskIntelligence: Sendable {
    public let llm: any LLMProvider
    public let model: String
    public init(llm: any LLMProvider, model: String = "sonnet") { self.llm = llm; self.model = model }

    public struct TaskContext: Sendable, Equatable {
        public let id: String
        public let owner: String?
        public let text: String
        public let meeting: String
        public init(id: String, owner: String?, text: String, meeting: String) {
            self.id = id; self.owner = owner; self.text = text; self.meeting = meeting
        }
    }

    public struct Plan: Codable, Sendable, Equatable {
        public struct Reword: Codable, Sendable, Equatable { public let id: String; public let text: String; public let owner: String? }
        public struct New: Codable, Sendable, Equatable { public let meetingID: String; public let owner: String?; public let text: String }
        public let reword: [Reword]
        public let complete: [String]     // task ids the evidence shows are DONE
        public let duplicates: [String]   // task ids redundant with another (the SAME action)
        public let add: [New]             // tasks the calls state but the list is missing
    }

    static let schema = #"""
    {"type":"object","additionalProperties":false,
     "properties":{
       "reword":{"type":"array","items":{"type":"object","additionalProperties":false,"properties":{"id":{"type":"string"},"text":{"type":"string"},"owner":{"type":["string","null"]}},"required":["id","text","owner"]}},
       "complete":{"type":"array","items":{"type":"string"}},
       "duplicates":{"type":"array","items":{"type":"string"}},
       "add":{"type":"array","items":{"type":"object","additionalProperties":false,"properties":{"meetingID":{"type":"string"},"owner":{"type":["string","null"]},"text":{"type":"string"}},"required":["meetingID","owner","text"]}}
     },
     "required":["reword","complete","duplicates","add"]}
    """#

    static let system = """
    You maintain a founder's action-item list across their meeting calls. You are given the CURRENT OPEN
    TASKS (each with an id, owner, and the call it came from) and EVIDENCE (the content of the calls).
    Return JSON describing how to tidy the list:
    - "reword": tasks to rewrite more clearly WITHOUT changing their meaning — {id, text, owner}. Keep it
      short and imperative, e.g. "Fix BitRouter reasoning-format inconsistency".
    - "complete": ids of tasks the evidence clearly shows are already DONE or handled.
    - "duplicates": ids of tasks that are redundant with ANOTHER task on the list (same action). List the
      redundant one's id (keep the clearest).
    - "add": tasks the calls clearly state as someone's to-do but that are MISSING from the list —
      {meetingID, owner, text}. Use a meetingID that appears in the EVIDENCE headers.
    RULES: Be conservative — only complete/duplicate/add when the evidence is clear. Never invent tasks,
    owners, or meeting ids. Every array must be present (use [] if nothing). Output JSON only.
    """

    public func reconcile(tasks: [TaskContext], evidence: String) async -> Plan? {
        guard !tasks.isEmpty || !evidence.isEmpty else { return nil }
        let taskList = tasks.isEmpty ? "(none)"
            : tasks.map { "- id=\($0.id) | owner=\($0.owner ?? "—") | from=\($0.meeting) | \($0.text)" }.joined(separator: "\n")
        let prompt = """
        CURRENT OPEN TASKS:
        \(taskList)

        EVIDENCE (call content):
        \(String(evidence.prefix(14000)))

        Return the tidy plan JSON.
        """
        guard let json = try? await llm.completeJSON(prompt: prompt, system: Self.system, schema: Self.schema,
                                                     model: model, timeout: 120),
              let data = json.data(using: .utf8),
              let plan = try? JSONDecoder().decode(Plan.self, from: data) else { return nil }
        return plan
    }
}
