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
    ("Fix the payments API reasoning format"). Empty list if none.

    Base EVERYTHING only on the transcript — never invent topics, owners, or tasks.
    """

    /// System prompt with the fenced personal-profile appendix (Task 1.4 + Codex phase-1 MED:
    /// summaries gloss jargon for the user too). Same subordination rules as the Ask path.
    static func system(profile: PersonalProfile?) -> String {
        guard let profile else { return system }
        return system + "\n\n" + profile.systemBlock
    }
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

    static func body(transcript: String, title: String, cap: Int? = nil) -> String {
        let t = cap.map { String(transcript.prefix($0)) } ?? transcript
        return "MEETING: \(title)\n\nTRANSCRIPT:\n\(t)\n\nReturn the summary JSON."
    }

    /// Split a long transcript into ≤`cap`-char windows on LINE boundaries, so no turn is cut
    /// mid-sentence and the TAIL is always covered (Task 6.7 — the old 24k prefix cap meant
    /// long calls were summarized from their first half; decisions live at the END of calls).
    static func windows(_ transcript: String, cap: Int) -> [String] {
        guard transcript.count > cap else { return [transcript] }
        var out: [String] = []
        var current = ""
        for rawLine in transcript.components(separatedBy: "\n") {
            // A single over-cap line (one enormous unpunctuated turn) is hard-split so no
            // window can exceed the local model's context (gate LOW).
            var pieces: [String] = []
            var rest = Substring(rawLine)
            while rest.count > cap { pieces.append(String(rest.prefix(cap))); rest = rest.dropFirst(cap) }
            pieces.append(String(rest))
            for line in pieces {
                if current.count + line.count + 1 > cap, !current.isEmpty {
                    out.append(current); current = ""
                }
                current += (current.isEmpty ? "" : "\n") + line
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    static func mergeBody(partials: [String], title: String) -> String {
        """
        MEETING: \(title)

        The meeting was summarized in \(partials.count) parts (in order). MERGE them into ONE \
        coherent summary in the required JSON format — dedupe repeated points, keep every \
        distinct decision and action item.

        \(partials.enumerated().map { "PART \($0.offset + 1):\n\($0.element)" }.joined(separator: "\n\n"))

        Return the merged summary JSON.
        """
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

    /// Who the summary is FOR (jargon glossing etc.) — fenced data, defaulted at the app edge.
    public var profile: PersonalProfile? = nil

    public init(model: String = "qwen2.5:3b", baseURL: URL = URL(string: "http://127.0.0.1:11434")!,
                numCtx: Int = 16384, keepAlive: String = "60s", profile: PersonalProfile? = nil) {
        self.model = model; self.baseURL = baseURL; self.numCtx = numCtx; self.keepAlive = keepAlive
        self.profile = profile
    }

    public func summarize(transcript: String, title: String) async -> CallSummary? {
        // Local-summaries v2 (founder: "the summaries are all pretty bad"): EXTRACT structured
        // facts per window (a 3B model is good at find-and-copy, bad at synthesis), MERGE facts
        // with dedupe, RENDER the markdown deterministically (structure + specificity by
        // construction), and let the model write only the one-sentence TL;DR.
        let windowCap = 20_000   // chars; num_ctx 16384 tokens comfortably fits this + prompt
        let windows = SummaryPrompt.windows(transcript, cap: windowCap)
        var parts: [MeetingFacts] = []
        for w in windows {
            // A FAILED window fails the whole local pass (gate MED: silently dropping a
            // middle/tail section while reporting success is a lie) — the caller falls back
            // to the next summarizer in its chain.
            guard let f = await extractFacts(transcript: w, title: title) else { return nil }
            parts.append(f)
        }
        var facts = MeetingFacts.merge(parts).sanitized()   // "Speaker 3" labels add nothing
        // A second, COMMITMENTS-ONLY pass over the full call: a focused single-category sweep
        // catches the "I'll…"/"can you…" moments the broad pass walks past (founder: "real
        // action items"). Merged + deduped against the broad pass's findings.
        if let extra = await extractCommitmentsOnly(transcript: transcript, title: title) {
            var seen = Set(facts.commitments.map { ($0.owner ?? "") + "|" + $0.task.lowercased() })
            for c in extra.map({ MeetingFacts.Commitment(owner: $0.owner, task: $0.task, due: $0.due) }) {
                let cleaned = MeetingFacts(commitments: [c]).sanitized().commitments[0]
                let k = (cleaned.owner ?? "") + "|" + cleaned.task.lowercased()
                // Fuzzy dedupe stays OWNER-SCOPED (gate HIGH: "Alice: review PR" must never
                // suppress "Bob: review PR" — the earlier owner-scoped rule applies here too).
                let sameOwnerTasks = facts.commitments
                    .filter { ($0.owner ?? "").lowercased() == (cleaned.owner ?? "").lowercased() }
                    .map(\.task)
                if !seen.contains(k),
                   !TaskIntelligence.isNearDuplicate(cleaned.task, of: sameOwnerTasks, strict: true) {
                    seen.insert(k); facts.commitments.append(cleaned)
                }
            }
        }
        guard !facts.isEmpty else {
            // A SUBSTANTIAL transcript that yielded zero facts means the local 3B model whiffed —
            // return nil so the caller falls back to the CLI summarizer, instead of shipping a
            // false "No substantive outcomes" for a real meeting (audit B7). Only a genuinely
            // short/trivial call gets the honest-empty summary.
            if transcript.count > 1500 { return nil }
            return CallSummary(summary: "**TL;DR:** \(FactPrompt.fallbackTLDR(facts))",
                               actionItems: [], source: "local")
        }
        var tldr = await composeTLDR(facts: facts, title: title) ?? FactPrompt.fallbackTLDR(facts)
        if FactPrompt.isVague(tldr) { tldr = FactPrompt.fallbackTLDR(facts) }   // mush tripwire
        let summary = FactPrompt.render(tldr: tldr, facts: facts)
        // REAL action items = the commitments people actually made — QUALITY-GATED and CAPPED
        // (founder: 26-38 raw extractions per call were noise; fewer, better).
        let items = FactPrompt.gateCommitments(facts.commitments).map { c in
            ActionItemDraft(owner: c.owner, text: c.due.map { "\(c.task) (\($0))" } ?? c.task)
        }
        return CallSummary(summary: summary, actionItems: items, source: "local")
    }

    /// The focused commitments sweep — one category, full attention (windowed like the rest).
    /// `complete` is false when any window failed (gate HIGH: callers gating one-time flags
    /// must distinguish partial from full success; summarize() merges partials happily).
    public func extractCommitmentsOnlyDetailed(transcript: String, title: String)
        async -> (items: [MeetingFacts.Commitment], complete: Bool)? {
        var out: [MeetingFacts.Commitment] = []
        for w in SummaryPrompt.windows(transcript, cap: 20_000) {
            guard let text = await rawGenerate(FactPrompt.commitmentsOnly(transcript: w, title: title),
                                               format: FactPrompt.commitmentsSchemaObject ?? "json",
                                               numPredict: 1024),
                  let parsed = FactPrompt.parseCommitments(text)
            else { return out.isEmpty ? nil : (out, false) }
            out.append(contentsOf: parsed)
        }
        return (out, true)
    }

    public func extractCommitmentsOnly(transcript: String, title: String) async -> [MeetingFacts.Commitment]? {
        await extractCommitmentsOnlyDetailed(transcript: transcript, title: title)?.items
    }

    /// One grammar-constrained extraction call over one window. Retries once unconstrained.
    func extractFacts(transcript: String, title: String) async -> MeetingFacts? {
        let prompt = FactPrompt.extraction(transcript: transcript, title: title)
        if let f = await generateFacts(prompt, useSchema: true) { return f }
        return await generateFacts(prompt, useSchema: false)
    }

    private func generateFacts(_ prompt: String, useSchema: Bool) async -> MeetingFacts? {
        guard let text = await rawGenerate(prompt,
                                           format: (useSchema ? FactPrompt.extractionSchemaObject : nil) ?? "json",
                                           numPredict: 2048)
        else { return nil }
        return FactPrompt.parseFacts(text)
    }

    /// The one prose call: a single TL;DR sentence (no JSON — plain text, tiny budget).
    private func composeTLDR(facts: MeetingFacts, title: String) async -> String? {
        guard let text = await rawGenerate(FactPrompt.tldr(facts: facts, title: title, profile: profile),
                                           format: nil, numPredict: 80)
        else { return nil }
        // Trim the WHOLE reply first — qwen loves a leading newline, which made the first
        // "line" empty and silently forced the deterministic fallback.
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\n").first?
            .trimmingCharacters(in: CharacterSet(charactersIn: " \"'")) ?? ""
        // Dense fact lists produce a ~300-char sentence — that's the "deeper insight" the
        // founder asked for, not a defect. Reject only the degenerate extremes.
        return (line.count >= 12 && line.count <= 420) ? line : nil
    }

    /// One Ollama /api/generate round-trip. `format` = JSON-schema object, "json", or nil (prose).
    private func rawGenerate(_ prompt: String, format: Any?, numPredict: Int) async -> String? {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/generate"))
        req.httpMethod = "POST"
        req.timeoutInterval = 240
        var payload: [String: Any] = [
            "model": model, "prompt": prompt, "stream": false, "keep_alive": keepAlive,
            "options": ["temperature": 0, "num_ctx": numCtx, "repeat_penalty": 1.1, "num_predict": numPredict],
        ]
        if let format { payload["format"] = format }
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = obj["response"] as? String else { return nil }
        return text
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
    public var profile: PersonalProfile? = nil
    public var label: String { "Cloud" }
    public init(llm: any LLMProvider, model: String = "sonnet", profile: PersonalProfile? = nil) {
        self.llm = llm; self.model = model; self.profile = profile
    }

    public func summarize(transcript: String, title: String) async -> CallSummary? {
        // Full transcript — the CLI models have ample context (Task 6.7: the 24k cap is gone).
        guard let json = try? await llm.completeJSON(prompt: SummaryPrompt.body(transcript: transcript, title: title),
                                                     system: SummaryPrompt.system(profile: profile), schema: SummaryPrompt.schema,
                                                     model: model, timeout: 180) else { return nil }
        return SummaryPrompt.parse(json, source: "cloud")
    }
}
