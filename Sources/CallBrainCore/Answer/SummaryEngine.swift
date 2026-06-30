import Foundation

/// A clean call summary + the action items it surfaced. The Summary tab shows action items first, then
/// the markdown summary.
public struct CallSummary: Sendable, Equatable {
    public let summary: String                 // markdown
    public let actionItems: [ActionItemDraft]
    public let source: String                  // "local" | "cloud" | "gemini"
    public init(summary: String, actionItems: [ActionItemDraft], source: String) {
        self.summary = summary; self.actionItems = actionItems; self.source = source
    }
}
public struct ActionItemDraft: Sendable, Equatable, Codable {
    public let owner: String?
    public let text: String
    public init(owner: String?, text: String) { self.owner = owner; self.text = text }
}

/// Anything that can turn a transcript into a structured summary. Implementations: a LOCAL model via
/// Ollama (free, private, on-device — the default) and the CLI subscription (Claude/Codex) for a premium
/// pass. The architecture lets us swap in any local model (Qwen, Llama, Gemma, Apple FM…) behind this.
public protocol Summarizer: Sendable {
    var label: String { get }
    func summarize(transcript: String, title: String) async -> CallSummary?
}

/// JSON the model returns (snake_case → mapped to `CallSummary`).
struct RawSummary: Codable {
    let summary: String
    let action_items: [ActionItemDraft]?
}

enum SummaryPrompt {
    static let system = """
    You summarize a meeting transcript for a busy founder. Return JSON only:
    {"summary": "<markdown>", "action_items": [{"owner": "<name or null>", "text": "<the task>"}]}

    "summary" is Markdown formatted EXACTLY like this (each heading on its own line, details as bullets
    BELOW it — never put content on the `##` line):

    **TL;DR:** <one orienting sentence>

    ## <Theme, e.g. Decisions>
    - **<lead term>** <specific detail with real names / numbers>
    - **<lead term>** <specific detail>

    ## <Theme, e.g. Blockers>
    - **<lead term>** <specific detail>

    Use 2-4 themed `##` sections covering what actually happened (decisions, updates, blockers, next
    steps). Be specific and concrete; no preamble, no "the meeting discussed" filler, no empty sections.

    "action_items": concrete to-dos the call actually states, each with the owner if a person is named
    (use the real name, not "the group"; null only if truly unassigned). Imperative and short
    ("Fix BitRouter reasoning format"). Empty list if none.

    Base EVERYTHING only on the transcript — never invent topics, owners, or tasks.
    """
    static let schema = #"""
    {"type":"object","additionalProperties":false,"properties":{"summary":{"type":"string"},"action_items":{"type":"array","items":{"type":"object","additionalProperties":false,"properties":{"owner":{"type":["string","null"]},"text":{"type":"string"}},"required":["owner","text"]}}},"required":["summary","action_items"]}
    """#

    static func parse(_ json: String, source: String) -> CallSummary? {
        guard let data = json.data(using: .utf8),
              let raw = try? JSONDecoder().decode(RawSummary.self, from: data) else { return nil }
        let s = raw.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        return CallSummary(summary: s, actionItems: raw.action_items ?? [], source: source)
    }

    static func body(transcript: String, title: String) -> String {
        // Generous cap — `num_ctx` is sized to fit this; M-series has the memory. Very long meetings are
        // truncated here (keeps the opening), which is fine for v1.
        "MEETING: \(title)\n\nTRANSCRIPT:\n\(String(transcript.prefix(24000)))\n\nReturn the summary JSON."
    }

    /// The schema as a decoded object, for Ollama's grammar-constrained structured output (`format`).
    static var schemaObject: Any? { (schema.data(using: .utf8)).flatMap { try? JSONSerialization.jsonObject(with: $0) } }
}

/// Local summarizer via the Ollama HTTP API (no key, no egress) — the default. Returns nil if the model
/// isn't available so the caller can fall back to the next summarizer (a smaller local model, then cloud).
///
/// Hardened per the model-selection research (2026-06-30): grammar-constrained JSON (full schema, not bare
/// `"json"`, so field names are guaranteed), an explicit `num_ctx` so long transcripts aren't silently
/// truncated to Ollama's 2048 default, `temperature: 0` for deterministic structure, a repeat-penalty +
/// `num_predict` cap against degenerate loops, and one retry on a parse miss.
public struct OllamaSummarizer: Summarizer {
    public let model: String
    public let baseURL: URL
    public let numCtx: Int
    /// How long Ollama keeps the model resident after a call. Short (not the 5-min default) so the ~9 GB
    /// 14B model isn't pinned in unified memory between bursts — but long enough to bridge a batch of
    /// back-to-back imports without a cold reload each time. The scheduler hard-unloads when fully idle.
    public let keepAlive: String
    public var label: String { "Local (\(model))" }

    public init(model: String = "qwen2.5:14b", baseURL: URL = URL(string: "http://127.0.0.1:11434")!,
                numCtx: Int = 16384, keepAlive: String = "60s") {
        self.model = model; self.baseURL = baseURL; self.numCtx = numCtx; self.keepAlive = keepAlive
    }

    public func summarize(transcript: String, title: String) async -> CallSummary? {
        let prompt = SummaryPrompt.system + "\n\n" + SummaryPrompt.body(transcript: transcript, title: title)
        // First attempt grammar-constrains output to our exact schema. If that misses (a build/model that
        // rejects an object `format`, or a parse miss), retry with bare `"json"` — a meaningfully different
        // request, not the same payload again. The prompt restates the schema either way.
        if let r = await generate(prompt, useSchema: true) { return r }
        return await generate(prompt, useSchema: false)
    }

    private func generate(_ prompt: String, useSchema: Bool) async -> CallSummary? {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/generate"))
        req.httpMethod = "POST"
        req.timeoutInterval = 240
        let format: Any = (useSchema ? SummaryPrompt.schemaObject : nil) ?? "json"
        let payload: [String: Any] = [
            "model": model, "prompt": prompt, "stream": false, "keep_alive": keepAlive,
            "format": format,
            "options": ["temperature": 0, "num_ctx": numCtx, "repeat_penalty": 1.1, "num_predict": 3072],
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = obj["response"] as? String else { return nil }
        return SummaryPrompt.parse(text, source: "local")
    }

    /// Evict the model from memory now (keep_alive: 0). Called when the summary queue drains so a big model
    /// stops drawing power / holding unified memory between sessions of work. Best-effort, never throws.
    public static func unload(model: String, baseURL: URL = URL(string: "http://127.0.0.1:11434")!) async {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/generate"))
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model, "keep_alive": 0])
        _ = try? await URLSession.shared.data(for: req)
    }
}

/// Cloud summarizer via the CLI subscription (Claude/Codex) — the "Regenerate / premium" pass.
public struct CLISummarizer: Summarizer {
    public let llm: any LLMProvider
    public let model: String
    public var label: String { "Cloud" }
    public init(llm: any LLMProvider, model: String = "sonnet") { self.llm = llm; self.model = model }

    public func summarize(transcript: String, title: String) async -> CallSummary? {
        guard let json = try? await llm.completeJSON(prompt: SummaryPrompt.body(transcript: transcript, title: title),
                                                     system: SummaryPrompt.system, schema: SummaryPrompt.schema,
                                                     model: model, timeout: 120) else { return nil }
        return SummaryPrompt.parse(json, source: "cloud")
    }
}
