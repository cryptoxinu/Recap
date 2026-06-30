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

    /// Ask a question. Returns a refusal envelope (no LLM call) when retrieval is empty.
    public func ask(_ query: String, topK: Int = 8) async throws -> Answer {
        let hits = try await search.hybrid(query, finalLimit: topK)
        guard !hits.isEmpty else {
            return Answer(status: .noSources,
                          text: "No indexed call contains evidence for that.",
                          citations: [], provider: nil, model: nil)
        }

        let refs = hits.enumerated().map { i, h in
            EvidenceRef(tag: "S\(i + 1)", chunkID: h.chunkID, meetingID: h.meetingID,
                        speaker: h.speaker, text: h.text)
        }
        let evidence = refs
            .map { "[\($0.tag)] \($0.speaker ?? "Unknown"): \($0.text)" }
            .joined(separator: "\n\n")
        let prompt = """
        SOURCES:
        \(evidence)

        QUESTION: \(query)

        Answer using ONLY the sources above, tagging each factual sentence with [S#]. \
        If they do not answer, reply exactly NO_SOURCED_EVIDENCE.
        """

        let completion = try await llm.complete(prompt: prompt, system: Self.systemPrompt, model: model)
        let text = completion.text.trimmingCharacters(in: .whitespacesAndNewlines)

        if text == "NO_SOURCED_EVIDENCE" || text.isEmpty {
            return Answer(status: .noSources, text: "No sourced evidence found.",
                          citations: [], provider: .claude, model: completion.model)
        }
        // Keep the citations actually referenced; if the model cited none, fall back to all offered.
        let used = refs.filter { text.contains("[\($0.tag)]") }
        return Answer(status: .answered, text: text,
                      citations: used.isEmpty ? refs : used,
                      provider: .claude, model: completion.model)
    }
}
