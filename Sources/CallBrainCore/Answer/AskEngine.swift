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

    /// One step in the transparent reasoning timeline (Phase 4.5). Each maps to REAL pipeline work —
    /// never fabricated theater. Emitted live via the `onStep` handler as the pipeline advances.
    public struct ReasoningStep: Sendable, Equatable, Identifiable {
        public let id: Int
        public let icon: String          // SF Symbol
        public let title: String
        public let detail: String
        public init(id: Int, icon: String, title: String, detail: String) {
            self.id = id; self.icon = icon; self.title = title; self.detail = detail
        }
    }
    /// Handler is MainActor-isolated so a SwiftUI model can update @Observable state directly.
    public typealias StepHandler = @MainActor @Sendable (ReasoningStep) async -> Void

    /// A few keywords from the question, for the "Searching for …" step.
    static func searchTerms(_ q: String) -> String {
        let stop: Set<String> = ["what","did","does","is","the","a","an","about","of","to","in","on",
                                 "and","me","my","our","we","you","for","with","how","was","were","are",
                                 "this","that","they","he","she","said","say","tell"]
        let words = q.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init)
            .filter { $0.count > 2 && !stop.contains($0) }
        return words.prefix(4).joined(separator: ", ")
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
    public func ask(_ query: String, topK: Int = 8, now: Date = Date(),
                    onStep: StepHandler? = nil) async throws -> Answer {
        let plan = QueryPlanner.plan(query, now: now)
        await onStep?(.init(id: 0, icon: "brain", title: "Understanding your question", detail: understandDetail(plan)))

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

        return try await answer(query, plan: plan, candidates: candidates, topK: topK, onStep: onStep)
    }

    /// Ask within a SINGLE meeting (the workspace AskFred). Retrieval is hard-filtered to that call's
    /// chunks, so every citation lands inside the same transcript (timestamp-linked navigation).
    public func ask(_ query: String, inMeeting meetingID: String, topK: Int = 8,
                    onStep: StepHandler? = nil) async throws -> Answer {
        let plan = QueryPlanner.plan(query)
        await onStep?(.init(id: 0, icon: "brain", title: "Understanding your question", detail: "Reading this call"))
        let candidates = try search.store.chunkIDs(meetingID: meetingID)
        guard !candidates.isEmpty else {
            return Answer(status: .noSources, text: "This call has no indexed content yet.",
                          citations: [], provider: nil, model: nil, plan: plan)
        }
        return try await answer(query, plan: plan, candidates: candidates, topK: topK, onStep: onStep)
    }

    private func understandDetail(_ plan: QueryPlan) -> String {
        if let dr = plan.dateRange { return "Scoped to \(dr.label)" }
        switch plan.mode {
        case .actionItems: return "Finding action items across your calls"
        case .person: return "Focusing on what a person said"
        case .technical: return "Looking for the explanation"
        default: return "Looking across all your calls"
        }
    }

    /// Shared core: retrieve over the candidate set → cited, validated answer (or grounded refusal).
    private func answer(_ query: String, plan: QueryPlan, candidates: [String]?, topK: Int,
                        onStep: StepHandler? = nil) async throws -> Answer {
        let terms = Self.searchTerms(query)
        await onStep?(.init(id: 1, icon: "magnifyingglass", title: "Searching your calls",
                            detail: terms.isEmpty ? "Finding the most relevant moments" : "for \(terms)"))
        let hits = try await search.hybrid(query, candidateChunkIDs: candidates, finalLimit: topK)
        guard !hits.isEmpty else {
            let scope = plan.dateRange.map { " from \($0.label)" } ?? ""
            return Answer(status: .noSources,
                          text: "Nothing in your calls\(scope) matches that.",
                          citations: [], provider: nil, model: nil, plan: plan)
        }

        let meetingCount = Set(hits.map(\.meetingID)).count
        await onStep?(.init(id: 2, icon: "doc.text.magnifyingglass", title: "Reading the relevant moments",
                            detail: "\(hits.count) passage\(hits.count == 1 ? "" : "s") across \(meetingCount) call\(meetingCount == 1 ? "" : "s")"))
        await onStep?(.init(id: 3, icon: "sparkles", title: "Writing a grounded answer",
                            detail: "Citing every claim back to your calls"))

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

        \(Self.modeInstruction(plan.mode))
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

    /// Per-mode framing instruction (Phase 4). Keeps the same grounded-and-cited core; only the shape of
    /// the answer changes. The deterministic `QueryPlanner.mode` chooses which one.
    static func modeInstruction(_ mode: AskMode) -> String {
        switch mode {
        case .general:
            return "Answer directly and concisely."
        case .person:
            return "Focus on what the named person actually said or committed to; attribute each point to them."
        case .timeScoped:
            return "Summarize the key updates, decisions, and open threads from this period as short bulleted points."
        case .actionItems:
            return "List the action items as a checklist. For EACH item state WHO owns it (in **bold**) and WHAT they must do. Group by owner. Include only tasks actually stated in the sources."
        case .technical:
            return "Explain clearly and precisely, defining any jargon. Prefer the sources that actually describe how it works."
        }
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
