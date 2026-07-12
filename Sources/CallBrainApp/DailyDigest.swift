import Foundation
import CallBrainCore

/// Perfection plan Task 7.4 — the Home "Daily Digest": 2-3 sentences on what happened across
/// the last day of calls. Built from the calls' EXISTING one-liner summaries (never the full
/// transcripts — this must be instant-cheap), polished by the local model when it's up, with a
/// deterministic assembly when it isn't. Cached once per day; regenerated when the day flips or
/// a new call lands.
extension Notification.Name {
    /// Fired when the local-model polish upgrades the digest text (Home updates live).
    static let cbDigestUpdated = Notification.Name("cb.digest.updated")
}

enum DailyDigest {
    static let cacheKey = "callbrain.dailyDigest"

    struct Cached: Codable, Equatable {
        let ymd: String
        let fingerprint: String   // corpus fingerprint (gate MED: count-only missed same-count edits)
        let text: String
    }

    static func cached(today: String, fingerprint: String) -> String? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let c = try? JSONDecoder().decode(Cached.self, from: data),
              c.ymd == today, c.fingerprint == fingerprint else { return nil }
        return c.text
    }

    static func save(_ text: String, today: String, fingerprint: String) {
        if let data = try? JSONEncoder().encode(Cached(ymd: today, fingerprint: fingerprint, text: text)) {
            UserDefaults.standard.set(data, forKey: cacheKey)
        }
    }

    /// Pull the fact-based TL;DR line out of a stored v2 summary (the digest's real fuel —
    /// the one-liner titles said "calls happened"; the TL;DRs say what MATTERED).
    static func tldrLine(fromSummary md: String?) -> String? {
        // Anchored: the TL;DR must OPEN a line within the first few lines (gate MED: an exact
        // unanchored search matched a mid-doc mention and missed case variants).
        guard let md else { return nil }
        for raw in md.components(separatedBy: "\n").prefix(4) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let lower = line.lowercased()
            for prefix in ["**tl;dr:**", "**tl;dr**:", "tl;dr:"] where lower.hasPrefix(prefix) {
                let content = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
                return content.isEmpty ? nil : content
            }
        }
        return nil
    }

    /// Deterministic digest — always works. Built from the calls' TL;DRs; the task count only
    /// appears when it's small enough to be signal (founder: "419 open items" is noise, not news).
    static func assemble(_ recent: [(title: String, oneLiner: String?)], openTasks: Int) -> String {
        guard !recent.isEmpty else {
            return openTasks > 0 && openTasks <= 30
                ? "No calls in the last day. \(openTasks) open action item\(openTasks == 1 ? "" : "s")."
                : "No calls in the last day. All caught up."
        }
        var lines: [String] = []
        for r in recent.prefix(3) {
            if var one = r.oneLiner, !one.isEmpty {
                if !one.hasSuffix(".") && !one.hasSuffix("!") { one += "." }
                lines.append(one)
            }
        }
        if lines.isEmpty {
            let names = recent.map(\.title).prefix(3).joined(separator: ", ")
            lines.append("\(recent.count) call\(recent.count == 1 ? "" : "s") in the last day: \(names).")
        }
        return lines.joined(separator: " ")
    }

    /// Local-model polish over the assembled facts (2-3 sentences, briefing voice). Falls back
    /// to the deterministic text on ANY failure — the digest never blocks and never bricks.
    static func polish(_ facts: String, recent: [(title: String, oneLiner: String?)],
                       forRole: String? = nil) async -> String? {
        let detail = recent.map { "- \($0.title): \($0.oneLiner ?? "")" }.joined(separator: "\n")
        // F12: the daily digest now reflects who the user is (was a generic "busy operator" briefing that
        // never used the configured profile).
        let trimmedRole = forRole?.trimmingCharacters(in: .whitespaces) ?? ""
        let who: String? = trimmedRole.isEmpty ? nil : trimmedRole
        let audience = who.map { "a \($0)" } ?? "a busy operator"
        let roleRule = who != nil ? "\n- Write it for their role; prefer plain language over unexplained jargon." : ""
        let prompt = """
        Write a 2-sentence briefing for \(audience) from these call takeaways. Rules:
        - LEAD with the single most consequential decision or blocker — not a list of calls.
        - Concrete names, versions, numbers. Never "you handled/managed/covered calls on…".
        - Never enumerate meeting titles. Never mention task counts. No preamble.\(roleRule)
        Takeaways:
        \(facts)
        \(detail)
        """
        var req = URLRequest(url: SystemStatus.ollamaBase.appendingPathComponent("api/generate"))
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": "qwen2.5:3b", "prompt": prompt, "stream": false, "keep_alive": "60s",
            "options": ["temperature": 0.2, "num_predict": 120],
        ])
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = obj["response"] as? String else { return nil }
        let out = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return (out.count > 20 && out.count < 600) ? out : nil
    }
}
