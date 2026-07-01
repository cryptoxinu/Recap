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

    /// Post-process a set of entities: merge spelling/case variants of the same person (so "Sunny" and
    /// "Sunney" don't both show), drop filler/tool false-positives, filter by count, rank, and cap. Pure —
    /// so it can ALSO be applied at display time to entities extracted before this cleanup existed
    /// (retroactively de-noising an existing library without a re-import).
    public static func clean(_ entities: [Entity], minCount: Int = 1, limit: Int = 40) -> [Entity] {
        // Drop obvious junk that may already be stored (filler mis-tags, tool names as people).
        let filtered = entities.filter { isPlausible($0.name, kind: $0.kind) }
        // Merge near-duplicate PERSON spellings ("Sunny"/"Sunney") into the higher-count canonical form.
        let merged = mergePersonVariants(filtered)
        return merged
            .filter { $0.count >= minCount }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
            .prefix(limit)
            .map { $0 }
    }

    /// Collapse person entities that are almost-certainly the same name spelled two ways — conservative:
    /// only when both are ≥4 chars, share the first two letters, and differ by a single edit. Keeps the
    /// higher-count spelling (tiebreak: the longer, more-complete form) and sums their counts.
    private static func mergePersonVariants(_ entities: [Entity]) -> [Entity] {
        var people = entities.filter { $0.kind == .person }.sorted { $0.count > $1.count }
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
    ]

    /// Tool / product / brand names the tagger sometimes mislabels as PEOPLE (they're not attendees).
    private static let toolNames: Set<String> = [
        "claude", "codex", "gpt", "chatgpt", "openai", "anthropic", "gemini", "bard", "copilot", "llama",
        "siri", "alexa", "cortana", "slack", "zoom", "notion", "figma", "github", "gitlab", "jira",
        "linear", "google", "meet", "teams", "webex", "discord", "fathom", "fireflies", "otter",
    ]

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
