import Foundation

/// Generates a "proper" meeting name + a one-line intelligence summary from a call's content, via the CLI
/// provider. Grounded: it describes only what's in the text — no invented topics. Used to upgrade the
/// filename-derived title (e.g. "morning sync") into "Ambient Morning Sync" + a smart descriptor under it.
public struct TitleIntelligence: Sendable {
    public let llm: any LLMProvider
    public let model: String
    public init(llm: any LLMProvider, model: String = "sonnet") { self.llm = llm; self.model = model }

    public struct Result: Sendable, Equatable, Codable {
        public let title: String
        public let summary: String
    }

    static let schema = #"""
    {"type":"object","additionalProperties":false,"properties":{"title":{"type":"string"},"summary":{"type":"string"}},"required":["title","summary"]}
    """#

    static let system = """
    You name meeting recordings. From the transcript/notes you are given, produce JSON with:
    - "title": a short, specific, human meeting name in Title Case (≤ 6 words) — the topic and/or who it
      was with, e.g. "Ambient Morning Sync" or "BitRouter Integration Review". No date, no quotes.
    - "summary": ONE line (≤ 12 words) naming the few concrete things discussed, e.g.
      "BitRouter live, Pearl GPU scaling, billing endpoint needed".
    Base BOTH only on the provided content — never invent topics or names. Output JSON only.
    """

    /// Returns nil on empty content or provider failure (caller keeps the existing title).
    public func generate(from text: String, fallbackTitle: String) async -> Result? {
        let clipped = String(text.prefix(8000))
        guard !clipped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let prompt = "CONTENT:\n\(clipped)\n\nReturn the title + summary JSON."
        guard let json = try? await llm.completeJSON(prompt: prompt, system: Self.system, schema: Self.schema,
                                                     model: model, timeout: 60),
              let data = json.data(using: .utf8),
              let r = try? JSONDecoder().decode(Result.self, from: data) else { return nil }
        let title = r.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = r.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        return Result(title: title, summary: summary)
    }
}
