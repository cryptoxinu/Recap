import Foundation

/// Which venture a call belongs to, so the founder can filter + tag meetings. The set is intentionally
/// small and fixed (the founder wears two hats); everything else is `other`.
public enum CallCategory: String, Sendable, CaseIterable, Codable {
    case ambient
    case furtherHealth = "further_health"
    case other

    public var label: String {
        switch self {
        case .ambient: "Ambient"
        case .furtherHealth: "Further Health"
        case .other: "Other"
        }
    }
    public init(stored: String?) { self = stored.flatMap(CallCategory.init(rawValue:)) ?? .other }
}

public struct CategoryResult: Sendable, Equatable {
    public let category: CallCategory
    public let confidence: Double         // 0…1
    public init(_ category: CallCategory, _ confidence: Double) { self.category = category; self.confidence = confidence }
}

/// Fast, deterministic, on-device classifier — keyword/term scoring over the call's text + participants.
/// The two ventures have very distinct vocabularies, so this alone is accurate on clear calls; ambiguous
/// ones (low confidence) escalate to the local LLM in `CategoryEngine`.
public enum CategoryHeuristic {
    // Decentralized-AI / crypto-inference (the founder's Ambient job).
    static let ambientTerms: [String] = [
        "ambient", "bitrouter", "proof of logits", "miner", "mining", "validator", "vllm", "gpu",
        "model router", "routing", "inference", "tokenomics", "decentrali", "blockchain", "web3",
        "staking", "spot pricing", "glm", "kimi", "gemma", "llama", "parakeet", "openrouter", "render",
        "pearl", "swe-bench", "intelligence index", "deepseek", "quantiz", "throughput", "tok/s",
        "tokens per second", "node operator", "crypto", "on-chain", "testnet", "mainnet",
    ]
    // Health & wellness (the founder's Further Health app).
    static let furtherTerms: [String] = [
        "further health", "healthbot", "health bot", "blood lab", "blood test", "blood work", "biomarker",
        "peptide", "genome", "genetic", "wearable", "whoop", "oura", "wellness", "patient", "clinical",
        "screening", "ferritin", "glucose", "cholesterol", "hormone", "testosterone", "nutrition",
        "longevity", "supplement", "vitamin", "lab result", "diagnos", "symptom", "hipaa", "wearables",
        "menopause", "fitness plan", "vo2", "hrv",
    ]

    public static func classify(_ text: String) -> CategoryResult {
        let t = text.lowercased()
        let a = score(t, ambientTerms)
        let f = score(t, furtherTerms)
        if a == 0 && f == 0 { return CategoryResult(.other, 0.25) }
        let total = a + f
        if a >= f {
            return CategoryResult(.ambient, confidence(win: a, total: total))
        } else {
            return CategoryResult(.furtherHealth, confidence(win: f, total: total))
        }
    }

    /// Distinct matched terms (not raw occurrences) so one repeated word can't dominate.
    static func score(_ text: String, _ terms: [String]) -> Int {
        terms.reduce(0) { $0 + (text.contains($1) ? 1 : 0) }
    }

    /// A dominant winner → high confidence; a near-tie → low (which triggers the LLM tiebreaker).
    static func confidence(win: Int, total: Int) -> Double {
        guard total > 0 else { return 0.25 }
        let share = Double(win) / Double(total)         // 0.5…1
        let strength = min(1.0, Double(win) / 4.0)      // few hits → less sure
        return min(1.0, share * (0.6 + 0.4 * strength))
    }
}

/// Local-LLM tiebreaker for ambiguous calls — Ollama, structured JSON, no egress. Returns nil if the
/// model is unavailable so the caller keeps the heuristic guess.
public struct CategoryClassifier: Sendable {
    public let model: String
    public let baseURL: URL
    public init(model: String = "qwen2.5:14b", baseURL: URL = URL(string: "http://127.0.0.1:11434")!) {
        self.model = model; self.baseURL = baseURL
    }

    static let system = """
    Classify a meeting into EXACTLY one category. Return JSON only: {"category": "...", "confidence": 0.0-1.0}
    - "ambient": a decentralized-AI / crypto-inference company. Signals: BitRouter, miners, GPUs, vLLM,
      validators, Proof of Logits, model routing, tokenomics, on-chain, GLM/Kimi/Gemma models, Render.
    - "further_health": a health & wellness product. Signals: Further Health / HealthBot, blood labs,
      biomarkers, peptides, genome, wearables, clinical/patient topics, nutrition, longevity.
    - "other": anything not clearly either (personal, vendor, recruiting, misc).
    Base it ONLY on the content. If genuinely unsure, use "other" with a low confidence.
    """
    static let schema = #"{"type":"object","additionalProperties":false,"properties":{"category":{"type":"string","enum":["ambient","further_health","other"]},"confidence":{"type":"number"}},"required":["category","confidence"]}"#

    struct Raw: Codable { let category: String; let confidence: Double? }

    public func classify(_ text: String) async -> CategoryResult? {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/generate"))
        req.httpMethod = "POST"
        req.timeoutInterval = 90
        let prompt = Self.system + "\n\nMEETING:\n" + String(text.prefix(6000)) + "\n\nReturn the JSON."
        let format: Any = (Self.schema.data(using: .utf8)).flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? "json"
        let payload: [String: Any] = [
            "model": model, "prompt": prompt, "stream": false, "keep_alive": "60s", "format": format,
            "options": ["temperature": 0, "num_ctx": 8192, "num_predict": 64],
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let textOut = obj["response"] as? String,
              let raw = try? JSONDecoder().decode(Raw.self, from: Data(textOut.utf8)),
              let cat = CallCategory(rawValue: raw.category) else { return nil }
        return CategoryResult(cat, min(1, max(0, raw.confidence ?? 0.6)))
    }
}

/// Classifies a call: the heuristic decides on clear calls (free + instant); ambiguous ones (low
/// confidence) ask the local LLM, falling back to the heuristic if it's unavailable.
public struct CategoryEngine: Sendable {
    public let classifier: CategoryClassifier?
    public init(classifier: CategoryClassifier? = CategoryClassifier()) { self.classifier = classifier }

    /// `confident` heuristic results short-circuit; below this, consult the LLM.
    static let escalateBelow = 0.6

    public func categorize(text: String) async -> CategoryResult {
        let h = CategoryHeuristic.classify(text)
        if h.confidence >= Self.escalateBelow { return h }
        if let llm = classifier, let r = await llm.classify(text) { return r }
        return h
    }
}
