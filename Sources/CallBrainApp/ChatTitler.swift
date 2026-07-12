import Foundation
import CallBrainCore

/// Task 7.5 — short topic titles for chat threads ("BitRouter billing status", not "What are my
/// action items"). Local model, tight budget, nil on any failure (the question-derived title stays).
enum ChatTitler {
    static func title(question: String, answer: String) async -> String? {
        let prompt = """
        Write a 2-5 word TITLE for this Q&A thread. Topic words only — no quotes, no punctuation,
        no "Chat about". Reply with ONLY the title.

        Q: \(String(question.prefix(300)))
        A: \(String(answer.prefix(500)))
        """
        var req = URLRequest(url: SystemStatus.ollamaBase.appendingPathComponent("api/generate"))
        req.httpMethod = "POST"
        req.timeoutInterval = 8
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": "qwen2.5:3b", "prompt": prompt, "stream": false, "keep_alive": "60s",
            "options": ["temperature": 0, "num_predict": 16],
        ])
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = obj["response"] as? String else { return nil }
        let cleaned = text.components(separatedBy: "\n").first?
            .trimmingCharacters(in: CharacterSet(charactersIn: " \"'`.,:;!"))
            .trimmingCharacters(in: .whitespaces) ?? ""
        let wordCount = cleaned.split(separator: " ").count
        guard (1...6).contains(wordCount), cleaned.count >= 4, cleaned.count <= 60 else { return nil }
        let lower = cleaned.lowercased()
        let junkPrefixes = ["chat about", "discussion", "conversation", "q&a", "title", "thread"]
        guard !junkPrefixes.contains(where: lower.hasPrefix) else { return nil }   // gate LOW
        return cleaned
    }
}
