import Foundation
import NaturalLanguage

/// Native on-device named-entity recognition (Apple's NaturalLanguage framework — no model download,
/// no network, no Python). Pulls the people, organizations, and places a meeting mentions so the
/// library can be filtered/searched by entity ("every call that mentioned BitRouter"). Phase 2.
public enum EntityKind: String, Sendable, Equatable, CaseIterable {
    case person, organization, place
}

public struct Entity: Sendable, Equatable, Identifiable {
    public let name: String
    public let kind: EntityKind
    public let count: Int
    public var id: String { "\(kind.rawValue):\(name.lowercased())" }
    public init(name: String, kind: EntityKind, count: Int) {
        self.name = name; self.kind = kind; self.count = count
    }
}

public enum EntityExtractor {
    /// Extract distinct named entities from text, ranked by mention count. `minCount` filters one-off
    /// noise; `limit` caps how many are kept per meeting. Names are normalized (trimmed, collapsed ws),
    /// filler/tool false-positives are dropped, and spelling variants of the same person are merged.
    public static func extract(_ text: String, minCount: Int = 1, limit: Int = 40) -> [Entity] {
        guard !text.isEmpty else { return [] }
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .joinNames]

        // key = "kind|lowercased name" → (display name, count)
        var counts: [String: (name: String, kind: EntityKind, n: Int)] = [:]
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word,
                             scheme: .nameType, options: options) { tag, range in
            guard let kind = kind(for: tag) else { return true }
            let name = normalize(String(text[range]))
            guard isPlausible(name, kind: kind) else { return true }
            let key = "\(kind.rawValue)|\(name.lowercased())"
            if let cur = counts[key] { counts[key] = (cur.name, kind, cur.n + 1) }
            else { counts[key] = (name, kind, 1) }
            return true
        }

        let raw = counts.values.map { Entity(name: $0.name, kind: $0.kind, count: $0.n) }
        return clean(raw, minCount: minCount, limit: limit)
    }

    /// Post-process a set of entities: merge spelling/case variants of the same person (so "Robin" and
    /// "Robin" don't both show), drop filler/tool false-positives, filter by count, rank, and cap. Pure —
    /// so it can ALSO be applied at display time to entities extracted before this cleanup existed
    /// (retroactively de-noising an existing library without a re-import).
    /// - Parameter trustedFullNames: lowercased full names known to be REAL people in this context (the
    ///   meeting's diarized/named speakers). A bare first name is only folded into a full name that appears
    ///   in this set — so "Chris" → "Chris Molle" only when Chris Molle actually spoke, never into an
    ///   arbitrary mention that might be a different person (scoped-audit MED). Empty ⇒ no first-name folding.
    public static func clean(_ entities: [Entity], minCount: Int = 1, limit: Int = 40,
                             trustedFullNames: Set<String> = []) -> [Entity] {
        // Strip leading filler the tagger prepends to a name ("Uh Riley", "Add Riley Novak") + re-aggregate.
        let stripped = reaggregate(entities.map { Entity(name: stripLeadingFiller($0.name), kind: $0.kind, count: $0.count) })
        // Drop obvious junk (filler mis-tags, tool names) AND multi-person concatenation artifacts
        // ("Noah Pederson Chris Molle Leo") — a real person name is 1–3 words.
        let filtered = stripped.filter {
            isPlausible($0.name, kind: $0.kind)
                && ($0.kind != .person || $0.name.split(separator: " ").count <= 3)
        }
        // Merge spelling variants ("Robin"/"Robin"), THEN fold a first-name-only mention into its full
        // name ("Riley" → "Riley Novak") — but only into a full name that's a real speaker of this call.
        let merged = coalesceFirstNames(mergePersonVariants(filtered), trusted: trustedFullNames)
        return merged
            .filter { $0.count >= minCount }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
            .prefix(limit)
            .map { $0 }
    }

    /// Leading interjections/verbs the tagger sometimes glues onto a name ("Uh Riley" / "Add Riley Novak").
    private static let leadingFiller = stoplist.union(["add"])
    private static func stripLeadingFiller(_ name: String) -> String {
        var tokens = name.split(separator: " ").map(String.init)
        while tokens.count > 1,
              leadingFiller.contains(tokens[0].lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".,!?"))) {
            tokens.removeFirst()
        }
        return tokens.joined(separator: " ")
    }

    /// Sum counts of entities that share a (kind, lowercased name) — collapses duplicates created by the
    /// filler strip (e.g. "Uh Riley" → "Riley" merging with an existing "Riley").
    private static func reaggregate(_ entities: [Entity]) -> [Entity] {
        var map: [String: (name: String, kind: EntityKind, n: Int)] = [:]
        for e in entities where !e.name.isEmpty {
            let key = "\(e.kind.rawValue)|\(e.name.lowercased())"
            if let cur = map[key] { map[key] = (cur.name, cur.kind, cur.n + e.count) }
            else { map[key] = (e.name, e.kind, e.count) }
        }
        return map.values.map { Entity(name: $0.name, kind: $0.kind, count: $0.n) }
    }

    /// Fold a first-name-only person ("Riley") into their full-name person ("Riley Novak") — but ONLY when
    /// that full name is a TRUSTED real speaker of the call AND is the only trusted full name starting with
    /// that first name. Grounding in actual speakers (not just any mention) is what keeps two different
    /// people who share a first name from collapsing (scoped-audit MED). Empty `trusted` ⇒ no folding.
    private static func coalesceFirstNames(_ entities: [Entity], trusted: Set<String>) -> [Entity] {
        guard !trusted.isEmpty else { return entities }
        var people = entities.filter { $0.kind == .person }
        let others = entities.filter { $0.kind != .person }
        func firstTok(_ n: String) -> String { (n.split(separator: " ").first.map(String.init) ?? n).lowercased() }
        // Merge targets = full names that are REAL people on this call (a diarized/named speaker).
        let fullIdx = people.indices.filter {
            people[$0].name.split(separator: " ").count >= 2 && trusted.contains(people[$0].name.lowercased())
        }
        var dropped = Set<Int>()
        for i in people.indices where people[i].name.split(separator: " ").count == 1 {
            let first = people[i].name.lowercased()
            let matches = fullIdx.filter { firstTok(people[$0].name) == first }
            guard matches.count == 1 else { continue }        // 0 = standalone/not-a-speaker · >1 = ambiguous
            let j = matches[0]
            people[j] = Entity(name: people[j].name, kind: .person, count: people[j].count + people[i].count)
            dropped.insert(i)
        }
        let kept = people.indices.filter { !dropped.contains($0) }.map { people[$0] }
        return kept + others
    }

    /// Collapse person entities that are almost-certainly the same name spelled two ways — conservative:
    /// only when both are ≥4 chars, share the first two letters, and differ by a single edit. Keeps the
    /// higher-count spelling (tiebreak: the longer, more-complete form) and sums their counts.
    private static func mergePersonVariants(_ entities: [Entity]) -> [Entity] {
        // Deterministic order (count desc, then name) — areSamePerson is non-transitive, so a stable fold
        // order guarantees the same input always merges the same way (audit LOW: order-dependent result).
        var people = entities.filter { $0.kind == .person }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
        let others = entities.filter { $0.kind != .person }
        var canonical: [Entity] = []
        for p in people {
            if let i = canonical.firstIndex(where: { areSamePerson($0.name, p.name) }) {
                let keep = canonical[i]
                // Prefer the spelling with the higher count; on a tie, the longer form.
                let name = keep.count != p.count ? keep.name : (keep.name.count >= p.name.count ? keep.name : p.name)
                canonical[i] = Entity(name: name, kind: .person, count: keep.count + p.count)
            } else {
                canonical.append(p)
            }
        }
        people = canonical
        return people + others
    }

    private static func areSamePerson(_ a: String, _ b: String) -> Bool {
        let x = a.lowercased(), y = b.lowercased()
        if x == y { return true }
        guard x.count >= 4, y.count >= 4 else { return false }        // never merge short names (Sam/Pam)
        guard x.prefix(2) == y.prefix(2) else { return false }        // must share a prefix
        return levenshtein(x, y) <= 1
    }

    /// Small bounded Levenshtein (only ever called on short display names).
    private static func levenshtein(_ a: String, _ b: String) -> Int {
        let s = Array(a), t = Array(b)
        if abs(s.count - t.count) > 1 { return 2 }                    // we only care about ≤1
        var prev = Array(0...t.count)
        var cur = [Int](repeating: 0, count: t.count + 1)
        for i in 1...s.count {
            cur[0] = i
            for j in 1...t.count {
                let cost = s[i - 1] == t[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &cur)
        }
        return prev[t.count]
    }

    private static func kind(for tag: NLTag?) -> EntityKind? {
        switch tag {
        case .personalName: .person
        case .organizationName: .organization
        case .placeName: .place
        default: nil
        }
    }

    private static func normalize(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Sentence-initial filler + interjections that NLTagger mis-tags as a name (capitalized after a
    /// period). Kept broad because a single stray "Wait,"/"Look," polluting the people list reads as a bug.
    private static let stoplist: Set<String> = [
        "um", "uh", "okay", "ok", "yeah", "yep", "yes", "no", "nope", "so", "well", "right", "hey", "hi",
        "hello", "thanks", "thank", "sure", "like", "and", "but", "the", "a", "an", "i", "we", "you",
        "actually", "basically", "honestly", "anyway", "cool", "nice", "good", "great", "sorry",
        "wait", "look", "listen", "let", "lets", "guys", "guy", "dude", "man", "yo", "oh", "hmm", "huh",
        "wow", "oops", "gotcha", "totally", "exactly", "absolutely", "definitely", "maybe", "perfect",
        "awesome", "amazing", "interesting", "true", "false", "done", "next", "first", "second", "then",
        "now", "today", "tomorrow", "yesterday", "here", "there", "everyone", "everybody", "anybody",
        "somebody", "nobody", "please", "welcome", "congrats", "congratulations", "alright", "yay",
        "damn", "shoot", "geez", "boom", "sweet", "gotcha", "hang", "hold", "stop", "go", "come",
        "aligned", "groovy", "dr", "job",   // recurring non-name words NLTagger mis-capitalizes as people
    ]

    /// Tool / product / brand / model names the tagger sometimes mislabels as PEOPLE (they're not
    /// attendees). All PUBLIC/generic products (safe to ship — no personal company names); the user's OWN
    /// ventures are excluded separately from the configured Settings list, not hardcoded here.
    static let toolNames: Set<String> = [
        "claude", "codex", "gpt", "chatgpt", "openai", "anthropic", "gemini", "bard", "copilot", "llama",
        "siri", "alexa", "cortana", "slack", "zoom", "notion", "figma", "github", "gitlab", "jira",
        "linear", "google", "meet", "teams", "webex", "discord", "fathom", "fireflies", "otter",
        // AI models / labs / dev + crypto products commonly discussed (public names, never people):
        "kimi", "moonshot", "gemma", "qwen", "mistral", "deepseek", "grok", "groq", "perplexity",
        "flux", "cuda", "nvidia", "pytorch", "tensorflow", "ollama", "langchain", "cursor", "docker",
        "kubernetes", "postgres", "redis", "nats", "vercel", "supabase", "render", "helm", "solana",
        "ethereum", "bitcoin", "defi", "uber", "alibaba", "java", "rust", "python", "golang", "typescript",
    ]

    /// Lowercase tech acronyms/terms that, when appearing as a TOKEN of a mis-tagged "name" ("Vera LLM",
    /// "Kimi K27"), mark it as a product reference rather than a person.
    static let techTerms: Set<String> = [
        "llm", "sdk", "api", "cli", "gpu", "cpu", "tee", "rpc", "sql", "css", "html", "ml", "ci", "cd",
        "kv", "db", "ui", "ux", "sdk", "vm", "os", "ip", "pr",   // "pr" catches NER glue like "Chris Tworkot PR"
    ]

    /// PUBLIC read-path plausibility for a PERSON display name — so the People roster (and other read
    /// paths) can reject NLTagger noise without duplicating the private rules. A real person name is 1–3
    /// words, passes the base plausibility (length/format/stoplist/toolName), and contains no tool/tech
    /// token (kills "Kimi K27", "Gemini Notes", "Moonshot AI", "Vera LLM").
    public static func isLikelyPersonName(_ name: String) -> Bool {
        let n = normalize(stripLeadingFiller(name))
        guard isPlausible(n, kind: .person) else { return false }
        let words = n.split(separator: " ").map { $0.lowercased() }
        guard (1...3).contains(words.count) else { return false }
        // A token that carries a DIGIT is a model/version reference ("Kimi K2.7", "Kimmy K27", "GLM52",
        // "FP8", "M5.2"), never a person name — real names don't contain digits.
        if words.contains(where: { $0.contains(where: \.isNumber) }) { return false }
        if words.contains(where: { toolNames.contains($0) || techTerms.contains($0) }) { return false }
        return true
    }

    /// True for an all-caps acronym ("AI", "UI", "API", "CUDA", "A16Z", "SWE") — never a person name.
    public static func isAcronym(_ name: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard (2...5).contains(n.count) else { return false }
        return !n.contains(where: { $0.isLowercase })
            && n.contains(where: { $0.isLetter })
            && n.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." }
    }

    /// Drop obvious junk: too short, all-lowercase fragments, pure numbers, filler words, or (for the
    /// person kind) tool/brand names that aren't actually attendees.
    private static func isPlausible(_ name: String, kind: EntityKind) -> Bool {
        guard name.count >= 2, name.count <= 60 else { return false }
        guard name.first?.isUppercase == true else { return false }
        guard name.contains(where: \.isLetter) else { return false }
        let lower = name.lowercased()
        if stoplist.contains(lower) { return false }
        if kind == .person, toolNames.contains(lower) { return false }
        return true
    }
}
