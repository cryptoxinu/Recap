import Foundation

/// Task 6.1 — local-model follow-up rewriting. "expand on the second point" retrieves garbage
/// under naive history-concat; the always-resident small model turns it into a standalone
/// search query in well under a second. STRICT budget + hard fallback: any failure, timeout,
/// or junk output returns nil and the caller keeps its deterministic heuristic.
public struct QueryRewriter: Sendable {
    public let model: String
    public let baseURL: URL
    public let timeout: TimeInterval

    public init(model: String = "qwen2.5:3b",
                baseURL: URL = URL(string: "http://127.0.0.1:11434")!,
                timeout: TimeInterval = 3) {
        self.model = model; self.baseURL = baseURL; self.timeout = timeout
    }

    public func rewrite(_ query: String, history: [AskEngine.Turn]) async -> String? {
        let recent = history.suffix(4).map { t in
            "\(t.role == .user ? "User" : "Assistant"): \(String(t.text.prefix(400)))"
        }.joined(separator: "\n")
        let prompt = """
        Rewrite the user's LAST message as ONE standalone search query over their meeting
        transcripts. Resolve pronouns and references ("that", "the second one", "him") using the
        conversation. Keep every concrete name/term. Reply with ONLY the query, nothing else.

        CONVERSATION:
        \(recent)

        LAST MESSAGE: \(query)
        """
        var req = URLRequest(url: baseURL.appendingPathComponent("api/generate"))
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": model, "prompt": prompt, "stream": false, "keep_alive": "60s",
            "options": ["temperature": 0, "num_predict": 64],
        ])
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = obj["response"] as? String else { return nil }
        let cleaned = text
            .components(separatedBy: "\n").first?
            .trimmingCharacters(in: CharacterSet(charactersIn: " \"'`"))
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Junk guards: must be a plausible query, not chatter or an essay.
        guard cleaned.count >= 6, cleaned.count <= 200,
              !cleaned.lowercased().hasPrefix("i "), !cleaned.lowercased().contains("sorry") else { return nil }
        return cleaned
    }
}
