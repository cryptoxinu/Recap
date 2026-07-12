import Foundation

/// One learned correction: a misheard form → its canonical form. Proper nouns / jargon ONLY — never
/// homophones or common words (curation + the human-approve gate on mined entries enforce this).
public struct CorrectionEntry: Codable, Equatable, Sendable, Identifiable {
    public enum Origin: String, Codable, Sendable { case seed, manual, mined }
    public var wrong: String       // matched case-INSENSITIVELY, whole-word
    public var right: String       // the canonical replacement (its exact casing is applied)
    public var origin: Origin
    /// Bumps when a user edits an entry — corrected transcripts version with it (never silent overwrite).
    public var version: Int
    public var id: String { wrong.lowercased() }

    public init(wrong: String, right: String, origin: Origin = .manual, version: Int = 0) {
        self.wrong = wrong; self.right = right; self.origin = origin; self.version = version
    }
}

/// The single GROWING correction dictionary shared by every mechanism (ASR prompt-biasing, the
/// deterministic apply-pass, click-to-correct, and AI mining all read/write THIS). Persisted in
/// UserDefaults (mirrors `PersonalProfile`). No model fine-tuning anywhere — that was the scoped trap.
public struct CorrectionDictionary: Codable, Equatable, Sendable {
    /// wrong→right corrections, applied deterministically after transcription.
    public var entries: [CorrectionEntry]
    /// Canonical proper nouns / jargon to BIAS the ASR toward (Whisper prompt tokens), so the terms are
    /// heard correctly at the SOURCE. Also the vocabulary the AI-mining pass looks for mistakes of.
    public var watchlist: [String]

    public init(entries: [CorrectionEntry] = [], watchlist: [String] = []) {
        self.entries = entries
        self.watchlist = watchlist
    }

    // MARK: Apply (deterministic, whole-word, case-insensitive match)

    /// A pre-compiled corrector: build ONCE per transcript (the regex is compiled here) and reuse across
    /// every line (audit LOW: don't recompile the combined regex per row).
    public struct Applicator: Sendable {
        fileprivate let re: NSRegularExpression?
        fileprivate let rightByWrong: [String: String]

        /// Apply the corrections to `text` — token-boundary, case-insensitive, canonical casing out, ONE
        /// pass against the ORIGINAL spans (a correction can't re-match another's output).
        public func apply(to text: String) -> String {
            guard let re, !text.isEmpty, !rightByWrong.isEmpty else { return text }
            let ns = text as NSString
            var out = ""
            var cursor = 0
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let r = m.range
                out += ns.substring(with: NSRange(location: cursor, length: r.location - cursor))
                let matched = ns.substring(with: r)
                out += rightByWrong[matched.lowercased()] ?? matched
                cursor = r.location + r.length
            }
            out += ns.substring(from: cursor)
            return out
        }
    }

    /// Compile a reusable `Applicator` from the current entries. Longest `wrong` first so "sole labs"
    /// beats "sole" (alternation is first-match), deterministic tie-break; exact no-op skip only (a
    /// case-only fix "ethereum"→"Ethereum" still applies). Non-alphanumeric lookarounds instead of `\b`
    /// so terms with non-word edges ("$SOL", "C#", ".NET") match on token boundaries without corruption.
    public func makeApplicator() -> Applicator {
        let valid = entries
            .map { (wrong: $0.wrong.trimmingCharacters(in: .whitespaces), right: $0.right) }
            .filter { !$0.wrong.isEmpty && $0.wrong != $0.right }
        guard !valid.isEmpty else { return Applicator(re: nil, rightByWrong: [:]) }
        var rightByWrong: [String: String] = [:]
        for v in valid { rightByWrong[v.wrong.lowercased()] = v.right }
        // Collapse replacement CHAINS (foo→bar, bar→baz ⇒ foo→baz) so apply() is idempotent across
        // repeated retroactive sweeps — otherwise a first pass's output ("bar") would be re-matched on the
        // next run and drift (audit MED). Depth-guarded so a pathological cycle can't loop forever.
        let base = rightByWrong
        rightByWrong = base.mapValues { Self.terminalReplacement($0, in: base, depth: 0) }
        let ordered = valid.map(\.wrong).sorted { a, b in a.count != b.count ? a.count > b.count : a < b }
        let alternation = ordered.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        let pattern = "(?<![A-Za-z0-9])(?:\(alternation))(?![A-Za-z0-9])"
        return Applicator(re: try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                          rightByWrong: rightByWrong)
    }

    /// Follow a replacement to its TERMINAL form: if `right` is itself a `wrong` key, keep resolving
    /// (depth-guarded against cycles) so chained corrections collapse to their final value.
    private static func terminalReplacement(_ right: String, in map: [String: String], depth: Int) -> String {
        guard depth < 16, let next = map[right.lowercased()], next.lowercased() != right.lowercased() else { return right }
        return terminalReplacement(next, in: map, depth: depth + 1)
    }

    /// Apply every correction to a single string (convenience — compiles an `Applicator` each call; for a
    /// batch of lines build one via `makeApplicator()` and reuse it).
    public func apply(to text: String) -> String {
        guard !entries.isEmpty, !text.isEmpty else { return text }
        return makeApplicator().apply(to: text)
    }

    /// A "wrong" term that would be RISKY to correct globally: too short, or a single common English word
    /// (homophone / common-word corruption). Multi-word phrases and terms with capitals or symbols read
    /// as proper nouns / jargon and are allowed. Used to gate click-to-correct + AI-mined entries.
    public static func isRiskyWrong(_ wrong: String) -> Bool {
        let w = wrong.trimmingCharacters(in: .whitespaces)
        if w.count < 2 { return true }
        let lower = w.lowercased()
        // A multi-word phrase, or one bearing a capital or a symbol, is treated as a name/jargon.
        if lower.contains(" ") { return false }
        if w.rangeOfCharacter(from: CharacterSet.uppercaseLetters) != nil { return false }
        if w.rangeOfCharacter(from: CharacterSet.alphanumerics.inverted) != nil { return false }
        return commonWords.contains(lower)
    }

    /// A modest common-English stopword set — enough to catch the obvious homophone/common-word mistakes
    /// ("there"→"their") without needing a full dictionary.
    static let commonWords: Set<String> = [
        "the","be","to","of","and","a","in","that","have","i","it","for","not","on","with","he","as","you",
        "do","at","this","but","his","by","from","they","we","say","her","she","or","an","will","my","one",
        "all","would","there","their","they're","what","so","up","out","if","about","who","get","which","go",
        "me","when","make","can","like","time","no","just","him","know","take","people","into","year","your",
        "good","some","could","them","see","other","than","then","now","look","only","come","its","over","think",
        "also","back","after","use","two","how","our","work","first","well","way","even","new","want","because",
        "any","these","give","day","most","us","is","are","was","were","been","has","had","did","yes","here",
        "there's","really","right","great","thing","things","need","sure","okay","let","much","more","very",
    ]

    /// Apply corrections across a whole parsed transcript (each utterance's text).
    public func apply(to transcript: ParsedTranscript) -> ParsedTranscript {
        guard !entries.isEmpty else { return transcript }
        var copy = transcript
        copy.utterances = transcript.utterances.map { u in
            var v = u; v.text = apply(to: u.text); return v
        }
        return copy
    }

    // MARK: ASR bias

    /// The glossary terms to feed Whisper as a conditioning prompt, deduped + capped. Right-hand
    /// canonical forms of corrections are included too (so a term we keep fixing gets heard correctly).
    /// Capped to `limit` terms (WhisperKit further trims to its ~half-context token budget).
    public func biasTerms(limit: Int = 60) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for term in watchlist + entries.map(\.right) {
            let t = term.trimmingCharacters(in: .whitespaces)
            let key = t.lowercased()
            guard !t.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key); out.append(t)
            if out.count >= limit { break }
        }
        return out
    }

    /// The conditioning-prompt STRING for Whisper (comma-joined glossary). Empty when no terms.
    public func biasPrompt(limit: Int = 60) -> String {
        let terms = biasTerms(limit: limit)
        return terms.isEmpty ? "" : terms.joined(separator: ", ")
    }

    // MARK: Mutation (immutable — returns a new dictionary)

    /// Add/replace a correction (keyed by lowercased `wrong`), bumping its version if it changed.
    public func upserting(_ entry: CorrectionEntry) -> CorrectionDictionary {
        var copy = self
        if let idx = copy.entries.firstIndex(where: { $0.id == entry.id }) {
            var e = entry
            if copy.entries[idx].right != entry.right { e.version = copy.entries[idx].version + 1 }
            copy.entries[idx] = e
        } else {
            copy.entries.append(entry)
        }
        // The corrected term becomes glossary vocabulary too (so the ASR learns to hear it).
        if !copy.watchlist.contains(where: { $0.lowercased() == entry.right.lowercased() }) {
            copy.watchlist.append(entry.right)
        }
        return copy
    }

    public func removingEntry(id: String) -> CorrectionDictionary {
        var copy = self; copy.entries.removeAll { $0.id == id }; return copy
    }

    public func addingWatch(_ term: String) -> CorrectionDictionary {
        let t = term.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !watchlist.contains(where: { $0.lowercased() == t.lowercased() }) else { return self }
        var copy = self; copy.watchlist.append(t); return copy
    }

    public func removingWatch(_ term: String) -> CorrectionDictionary {
        var copy = self; copy.watchlist.removeAll { $0.lowercased() == term.lowercased() }; return copy
    }

    // MARK: Persistence

    public static let defaultsKey = "callbrain.correctionDictionary.v1"

    public func save(key: String = Self.defaultsKey) {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: key) }
    }

    /// Load the saved dictionary, MERGED over the shipped seed so new seed terms appear for existing
    /// users without clobbering their learned corrections.
    public static func load(key: String = Self.defaultsKey) -> CorrectionDictionary {
        guard let data = UserDefaults.standard.data(forKey: key),
              let saved = try? JSONDecoder().decode(CorrectionDictionary.self, from: data) else {
            return seeded
        }
        var merged = saved
        for term in seeded.watchlist where !merged.watchlist.contains(where: { $0.lowercased() == term.lowercased() }) {
            merged.watchlist.append(term)
        }
        for entry in seeded.entries where !merged.entries.contains(where: { $0.id == entry.id }) {
            merged.entries.append(entry)
        }
        return merged
    }

    /// Mined-correction proposals the user REJECTED (deselected or cancelled) in the "Train with AI" review.
    /// Remembered so the stochastic miner doesn't keep re-surfacing the same ones you already said no to.
    /// Keyed by "heard→shouldBe" (lowercased); persisted in UserDefaults alongside the dictionary.
    public enum RejectedProposals {
        static let key = "callbrain.rejectedCorrections.v1"
        public static func rejectionKey(heard: String, shouldBe: String) -> String {
            heard.lowercased().trimmingCharacters(in: .whitespaces) + "\u{2192}"
                + shouldBe.lowercased().trimmingCharacters(in: .whitespaces)
        }
        public static func load() -> Set<String> { Set(UserDefaults.standard.stringArray(forKey: key) ?? []) }
        public static func remember(_ keys: [String]) {
            guard !keys.isEmpty else { return }
            var s = load(); keys.forEach { s.insert($0) }
            UserDefaults.standard.set(Array(s), forKey: key)
        }
    }

    /// Shipped seed: a crypto / web3 glossary to bias the ASR + a few high-confidence corrections. Only
    /// proper nouns + jargon (never homophones). Grows via click-to-correct and AI mining.
    public static let seeded = CorrectionDictionary(
        entries: [
            CorrectionEntry(wrong: "aetherium", right: "Ethereum", origin: .seed),
            CorrectionEntry(wrong: "etherium", right: "Ethereum", origin: .seed),
            CorrectionEntry(wrong: "solano", right: "Solana", origin: .seed),
            CorrectionEntry(wrong: "def i", right: "DeFi", origin: .seed),
            CorrectionEntry(wrong: "stable coin", right: "stablecoin", origin: .seed),
            CorrectionEntry(wrong: "arbitram", right: "Arbitrum", origin: .seed),
            CorrectionEntry(wrong: "chain link", right: "Chainlink", origin: .seed),
            CorrectionEntry(wrong: "polygone", right: "Polygon", origin: .seed),
        ],
        watchlist: [
            // Chains / protocols
            "Ethereum", "Solana", "Bitcoin", "Arbitrum", "Optimism", "Polygon", "Base", "Avalanche",
            "Chainlink", "Uniswap", "Aave", "Coinbase", "Binance",
            // Jargon
            "DeFi", "stablecoin", "tokenomics", "liquidity", "staking", "restaking", "rollup", "zk-rollup",
            "L2", "airdrop", "onchain", "wallet", "smart contract", "gas fees", "yield", "AMM", "TVL",
            "mainnet", "testnet", "validator", "nonce", "USDC", "USDT",
            // The app's own name (not personal). Add your own product/company terms in
            // Settings → Vocabulary so they transcribe with the right casing.
            "Recap",
        ]
    )
}
