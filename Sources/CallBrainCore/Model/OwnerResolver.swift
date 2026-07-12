import Foundation

/// Collapses the many spellings a task owner appears under into one canonical display name — applied at
/// DISPLAY time (like `SpeakerResolver`) so it retroactively de-fragments an existing task list without a
/// re-import. Deterministic, no AI: it clusters the owner strings the corpus already contains.
///
/// The real pain: the SAME person shows up as "Sam" / "Sam Ortiz" / "Samuel Ortiz", and Whisper mis-hears
/// surnames so "Priya Nadkarni" also appears as "Nadkarnee / Nadkarny / Nadkarn" — several sections for one
/// person, which reads as broken AI noise and scatters their tasks. This folds them.
///
/// Two safe merges only (conservative — a WRONG merge mislabels who owes what):
/// 1. **First-name → full-name**: a bare first name ("Sam") folds into the one full name that starts with
///    it ("Samuel Ortiz"), but ONLY when that first name maps to exactly one full-name cluster (two
///    different "Chris"es stay "Chris").
/// 2. **Misspelled surname**: full names sharing a first name whose surnames are near-identical (small
///    edit distance, or one a prefix of the other) are one person → the most-frequent well-formed spelling
///    wins as canonical.
public enum OwnerResolver {

    /// Build a raw-owner → canonical-display-name map from the owner frequencies across the task list.
    /// `ownerCounts` = distinct raw owner string → how many tasks carry it (frequency breaks ties toward
    /// the spelling the founder sees most). Multi-owner comma blobs are canonicalized part-by-part.
    public static func canonicalMap(ownerCounts: [String: Int]) -> [String: String] {
        // Normalize + split single vs multi-owner. A comma blob's PARTS also feed the clustering (so a
        // name that only ever appears inside a blob still gets canonicalized), then the blob is rebuilt
        // from each part's canonical form.
        var singleCounts: [String: Int] = [:]
        for (raw, n) in ownerCounts {
            let t = normalize(raw)
            guard !t.isEmpty else { continue }
            if t.contains(",") {
                for p in t.split(separator: ",").map({ normalize(String($0)) }) where !p.isEmpty {
                    singleCounts[p, default: 0] += n
                }
            } else {
                singleCounts[t, default: 0] += n
            }
        }

        let singleCanon = clusterSingles(singleCounts)   // normalized single name → canonical

        // Assemble the final map keyed by the ORIGINAL raw string (so the caller can look up any row).
        var out: [String: String] = [:]
        for raw in ownerCounts.keys {
            let t = normalize(raw)
            if t.isEmpty { continue }
            if t.contains(",") {
                let parts = t.split(separator: ",").map { normalize(String($0)) }.filter { !$0.isEmpty }
                let canonParts = parts.map { singleCanon[$0] ?? titleCased($0) }
                // De-dup parts that canonicalized to the same person, preserve order.
                var seen = Set<String>(); var uniq: [String] = []
                for p in canonParts where seen.insert(p.lowercased()).inserted { uniq.append(p) }
                out[raw] = uniq.joined(separator: ", ")
            } else {
                out[raw] = singleCanon[t] ?? titleCased(t)
            }
        }
        return out
    }

    // MARK: - clustering

    private static func clusterSingles(_ counts: [String: Int]) -> [String: String] {
        let fulls = counts.keys.filter { tokenCount($0) >= 2 }
        let bares = counts.keys.filter { tokenCount($0) == 1 }

        // Cluster the full names: two are the SAME person when their first names are compatible (equal, or
        // one an abbreviation-prefix of the other: "Sam"⊂"Samuel", "Dan"⊂"Daniel") AND their surnames
        // are near-identical (`|~`). Seed most-frequent-first; the name string is the FINAL tiebreaker so
        // the clustering is fully deterministic regardless of Dictionary key-iteration order (a same-count,
        // same-length tie must not pick a different seed run-to-run — audit determinism).
        let ordered = fulls.sorted { a, b in
            let ka = (counts[a] ?? 0, a.count), kb = (counts[b] ?? 0, b.count)
            return ka != kb ? ka > kb : a < b
        }
        var clusters: [[String]] = []
        for name in ordered {
            if let i = clusters.firstIndex(where: { firstNameCompat($0[0], name) && (surname($0[0]) |~ surname(name)) }) {
                clusters[i].append(name)
            } else {
                clusters.append([name])
            }
        }

        var map: [String: String] = [:]
        var canonOf: [Int: String] = [:]
        for (i, cluster) in clusters.enumerated() {
            let canon = canonicalName(of: cluster, counts: counts)
            canonOf[i] = canon
            for n in cluster { map[n] = canon }
        }

        // A bare first name folds into a full-name cluster ONLY if EXACTLY ONE cluster's first name is
        // compatible with it — otherwise it's ambiguous (two people share the first name) and stays as-is.
        for b in bares {
            let matches = clusters.indices.filter { firstNameCompat(clusters[$0][0], b) }
            map[b] = matches.count == 1 ? (canonOf[matches[0]] ?? titleCased(b)) : titleCased(b)
        }
        return map
    }

    /// First names are compatible when equal, or one is an abbreviation-prefix of the other (≥3 chars:
    /// "Sam"⊂"Samuel", "Dan"⊂"Daniel") — but NOT for a full name vs a DIFFERENT first name.
    static func firstNameCompat(_ a: String, _ b: String) -> Bool {
        let fa = firstToken(a), fb = firstToken(b)
        if fa == fb { return true }
        let (short, long) = fa.count <= fb.count ? (fa, fb) : (fb, fa)
        return short.count >= 3 && long.hasPrefix(short)
    }

    /// The canonical spelling for a cluster: the most-frequent, then the longest, then alphabetically
    /// first — the last key makes ties deterministic (no dependence on iteration order).
    private static func canonicalName(of cluster: [String], counts: [String: Int]) -> String {
        let best = cluster.max { a, b in
            let ka = (counts[a] ?? 0, a.count), kb = (counts[b] ?? 0, b.count)
            return ka != kb ? ka < kb : a > b
        } ?? cluster[0]
        return titleCased(best)
    }

    // MARK: - string helpers

    static func normalize(_ s: String) -> String {
        // Drop parenthetical asides the notes/LLM leave on owners — "Dana (Danielle)", "Sam (or Dan)" —
        // which otherwise read as distinct multi-token "people" and block folding.
        s.replacingOccurrences(of: #"\([^)]*\)"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }
    static func firstToken(_ s: String) -> String {
        (s.split(separator: " ").first.map(String.init) ?? s).lowercased()
    }
    static func tokenCount(_ s: String) -> Int { s.split(separator: " ").count }
    static func surname(_ s: String) -> String {
        (s.split(separator: " ").last.map(String.init) ?? s).lowercased()
    }
    /// Title-case each token, preserving intra-token capitals-after-first only lightly (keeps "Mced" as-is
    /// is overkill — a simple first-letter-uppercase per token reads clean for names).
    static func titleCased(_ s: String) -> String {
        s.split(separator: " ").map { w -> String in
            guard let f = w.first else { return String(w) }
            return f.uppercased() + w.dropFirst()
        }.joined(separator: " ")
    }
}

/// Near-equal surnames: identical, one a prefix of the other (≥4 chars), a long shared PREFIX (Whisper
/// gets a surname's start right and mangles its end — "Nadkarni → Nadkarnee/…karny/…karn" all share
/// "nadkar"), or Levenshtein ≤2 on names ≥5 chars. Tight so distinct surnames ("Molle" vs "Pederson",
/// prefix 0) never merge.
infix operator |~: ComparisonPrecedence
private func |~ (a: String, b: String) -> Bool {
    if a == b { return true }
    let (short, long) = a.count <= b.count ? (a, b) : (b, a)
    if short.count >= 4 && long.hasPrefix(short) { return true }
    let cp = commonPrefixLen(a, b)
    if cp >= 5 && Double(cp) >= 0.6 * Double(short.count) { return true }
    guard short.count >= 5 else { return false }
    return levenshtein(a, b) <= 2
}

private func commonPrefixLen(_ a: String, _ b: String) -> Int {
    var n = 0
    for (x, y) in zip(a, b) { if x == y { n += 1 } else { break } }
    return n
}

private func levenshtein(_ a: String, _ b: String) -> Int {
    let x = Array(a), y = Array(b)
    if x.isEmpty { return y.count }
    if y.isEmpty { return x.count }
    var prev = Array(0...y.count)
    var cur = [Int](repeating: 0, count: y.count + 1)
    for i in 1...x.count {
        cur[0] = i
        for j in 1...y.count {
            let cost = x[i - 1] == y[j - 1] ? 0 : 1
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
        }
        swap(&prev, &cur)
    }
    return prev[y.count]
}
