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
    /// noise; `limit` caps how many are kept per meeting. Names are normalized (trimmed, collapsed ws).
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
            guard isPlausible(name) else { return true }
            let key = "\(kind.rawValue)|\(name.lowercased())"
            if let cur = counts[key] { counts[key] = (cur.name, kind, cur.n + 1) }
            else { counts[key] = (name, kind, 1) }
            return true
        }

        return counts.values
            .filter { $0.n >= minCount }
            .sorted { $0.n != $1.n ? $0.n > $1.n : $0.name < $1.name }
            .prefix(limit)
            .map { Entity(name: $0.name, kind: $0.kind, count: $0.n) }
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

    /// Sentence-initial filler that NLTagger sometimes mis-tags as a name (capitalized after a period).
    private static let stoplist: Set<String> = [
        "um", "uh", "okay", "ok", "yeah", "yep", "yes", "no", "so", "well", "right", "hey", "hi",
        "hello", "thanks", "thank", "sure", "like", "and", "but", "the", "a", "an", "i", "we", "you",
        "actually", "basically", "honestly", "anyway", "cool", "nice", "good", "great", "sorry",
    ]

    /// Drop obvious junk: too short, all-lowercase fragments, pure numbers, or filler words.
    private static func isPlausible(_ name: String) -> Bool {
        guard name.count >= 2, name.count <= 60 else { return false }
        guard name.first?.isUppercase == true else { return false }
        guard name.contains(where: \.isLetter) else { return false }
        if stoplist.contains(name.lowercased()) { return false }
        return true
    }
}
