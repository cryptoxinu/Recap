import Foundation

/// The headless "ask" loop (docs/ARCHITECTURE.md §7): query → hybrid retrieve → assemble numbered,
/// cited evidence → generate via the CLI → citation-checked answer. Enforces the cardinal rule:
/// the model only writes prose over a pre-retrieved, pre-cited evidence set, and **refuses before
/// spending any LLM quota when there is no evidence**.
public struct AskEngine: Sendable {
    public let search: SearchEngine
    public let llm: ClaudeRunner
    public let model: String

    public init(search: SearchEngine, llm: ClaudeRunner, model: String = "sonnet") {
        self.search = search; self.llm = llm; self.model = model
    }

    public struct EvidenceRef: Sendable, Equatable {
        public let tag: String          // "S1"
        public let chunkID: String
        public let meetingID: String
        public let speaker: String?
        public let text: String
    }

    public struct Answer: Sendable, Equatable {
        public enum Status: String, Sendable { case answered, noSources }
        public let status: Status
        public let text: String
        public let citations: [EvidenceRef]
        public let provider: ProviderID?
        public let model: String?
        public var plan: QueryPlan? = nil       // the deterministic plan (date window / mode) used
    }

    static let systemPrompt = """
    You are CallBrain, answering questions strictly from a user's own meeting transcripts.
    RULES (non-negotiable):
    - Use ONLY the numbered SOURCES provided. Never use outside knowledge.
    - Tag every factual sentence with its source like [S1] or [S2][S3].
    - Separate CONFIRMED facts (directly stated) from INFERRED reasoning (put inference under a clearly hedged heading).
    - Never invent speakers, dates, numbers, or quotes. Quote verbatim when quoting.
    - If the SOURCES do not answer the question, reply with exactly: NO_SOURCED_EVIDENCE
    """

    /// Ask a question. Returns a refusal envelope (no LLM call) when retrieval is empty. `now` is the
    /// clock used for date-gating (injectable for tests). A time-scoped question ("this week") becomes a
    /// HARD candidate filter — evidence can ONLY come from inside the window, never outside it.
    public func ask(_ query: String, topK: Int = 8, now: Date = Date()) async throws -> Answer {
        let plan = QueryPlanner.plan(query, now: now)

        var candidates: [String]? = nil
        if let dr = plan.dateRange {
            let ids = try search.store.chunkIDs(fromYMD: dr.startYMD, toYMDExclusive: dr.endYMDExclusive)
            if ids.isEmpty {
                return Answer(status: .noSources,
                              text: "You don't have any calls from \(dr.label).",
                              citations: [], provider: nil, model: nil, plan: plan)
            }
            candidates = ids
        }

        let hits = try await search.hybrid(query, candidateChunkIDs: candidates, finalLimit: topK)
        guard !hits.isEmpty else {
            let scope = plan.dateRange.map { " from \($0.label)" } ?? ""
            return Answer(status: .noSources,
                          text: "Nothing in your calls\(scope) matches that.",
                          citations: [], provider: nil, model: nil, plan: plan)
        }

        let refs = hits.enumerated().map { i, h in
            EvidenceRef(tag: "S\(i + 1)", chunkID: h.chunkID, meetingID: h.meetingID,
                        speaker: h.speaker, text: h.text)
        }
        let evidence = refs
            .map { "[\($0.tag)] \($0.speaker ?? "Unknown"): \($0.text)" }
            .joined(separator: "\n\n")
        let scopeNote = plan.dateRange.map {
            "These sources are ALL from \($0.label) — answer only about that period.\n\n"
        } ?? ""
        let prompt = """
        \(scopeNote)SOURCES:
        \(evidence)

        QUESTION: \(query)

        Answer using ONLY the sources above, tagging each factual sentence with [S#]. \
        If they do not answer, reply exactly NO_SOURCED_EVIDENCE.
        """

        let completion = try await llm.complete(prompt: prompt, system: Self.systemPrompt, model: model)
        let text = completion.text.trimmingCharacters(in: .whitespacesAndNewlines)

        if text == "NO_SOURCED_EVIDENCE" || text.isEmpty {
            return Answer(status: .noSources, text: "No sourced evidence found.",
                          citations: [], provider: .claude, model: completion.model, plan: plan)
        }
        // Citation validation (anti-hallucination, Codex Phase-1 fix): keep ONLY refs that were actually
        // cited with a VALID [S#] tag. If the model grounded nothing valid in the sources, refuse rather
        // than present unsourced text or attach all sources as if cited.
        let referenced = Self.referencedTags(in: text)
        let cited = refs.filter { referenced.contains($0.tag) }
        guard !cited.isEmpty else {
            return Answer(status: .noSources,
                          text: "I couldn't ground an answer to that in your calls — try rephrasing or importing more.",
                          citations: [], provider: .claude, model: completion.model, plan: plan)
        }
        return Answer(status: .answered, text: text, citations: cited,
                      provider: .claude, model: completion.model, plan: plan)
    }

    /// The set of `S#` tags the answer actually references (from `[S#]` markers).
    static func referencedTags(in text: String) -> Set<String> {
        guard let re = try? NSRegularExpression(pattern: #"\[(S\d+)\]"#) else { return [] }
        let ns = text as NSString
        var tags = Set<String>()
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            tags.insert(ns.substring(with: m.range(at: 1)))
        }
        return tags
    }
}
