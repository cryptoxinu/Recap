import Foundation

/// Speaker-turn-aware, citation-stable chunker (docs/ARCHITECTURE.md §6.5).
///
/// Builds retrieval chunks from a meeting's ordered utterances: it greedily packs one speaker's
/// consecutive turns up to `targetTokens`, and **never splits across a speaker change** unless a single
/// monologue exceeds `maxTokens` (then it splits at sentence boundaries, carrying `overlapTokens`).
/// This keeps "who said what" intact so speaker-filtered retrieval is exact.
///
/// Token counts are an approximation (~1.33 × word count) until the embedding model's tokenizer is wired.
public struct Chunker: Sendable {
    public let targetTokens: Int
    public let overlapTokens: Int
    public let maxTokens: Int

    public init(targetTokens: Int = 512, overlapTokens: Int = 128, maxTokens: Int = 768) {
        self.targetTokens = targetTokens
        self.overlapTokens = overlapTokens
        self.maxTokens = maxTokens
    }

    /// A chunk before the ingest layer attaches the final `chunk_id` + `Citation`.
    public struct Chunk: Sendable, Equatable {
        public var seq: Int
        public var speaker: String
        public var tStart: Double
        public var tEnd: Double
        public var text: String
        public var utteranceSeqs: [Int]
        public var approxTokens: Int
    }

    public func chunk(_ utterances: [Utterance]) -> [Chunk] {
        var chunks: [Chunk] = []
        var cur: [Utterance] = []

        func curTokens() -> Int { cur.reduce(0) { $0 + Self.approxTokens($1.text) } }
        func emit() {
            guard !cur.isEmpty else { return }
            let text = cur.map(\.text).joined(separator: " ")
            chunks.append(Chunk(seq: chunks.count, speaker: cur[0].speakerRaw,
                                tStart: cur.first!.tStart, tEnd: cur.last!.tEnd, text: text,
                                utteranceSeqs: cur.map(\.seq), approxTokens: Self.approxTokens(text)))
            cur = []
        }

        for u in utterances {
            // A monologue larger than the hard cap: flush, then split it on its own.
            if Self.approxTokens(u.text) > maxTokens {
                emit()
                for piece in Self.splitLong(u.text, maxTokens: maxTokens, overlapTokens: overlapTokens) {
                    chunks.append(Chunk(seq: chunks.count, speaker: u.speakerRaw,
                                        tStart: u.tStart, tEnd: u.tEnd, text: piece,
                                        utteranceSeqs: [u.seq], approxTokens: Self.approxTokens(piece)))
                }
                continue
            }
            // Speaker change → close the current chunk (never mix speakers).
            if let first = cur.first, first.speakerRaw != u.speakerRaw { emit() }
            // Would exceed the target → close first.
            if !cur.isEmpty, curTokens() + Self.approxTokens(u.text) > targetTokens { emit() }
            cur.append(u)
        }
        emit()
        return chunks
    }

    // MARK: - helpers

    static func approxTokens(_ s: String) -> Int {
        let words = s.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).count
        return Int((Double(words) * 1.33).rounded(.up))
    }

    /// Split an over-cap monologue at sentence boundaries, carrying `overlapTokens` worth of trailing
    /// sentences into the next piece for retrieval continuity.
    static func splitLong(_ text: String, maxTokens: Int, overlapTokens: Int) -> [String] {
        let sentences = splitSentences(text)
        guard !sentences.isEmpty else { return [text] }

        var pieces: [String] = []
        var cur: [String] = []
        var curTok = 0

        for sentence in sentences {
            let t = approxTokens(sentence)
            // A SINGLE sentence over the cap (an unpunctuated monologue / auto-transcript with no
            // `.?!`) can't be placed whole — window it by words with overlap, else the chunk exceeds
            // maxTokens and the embedder silently truncates it, dropping content (audit D14).
            if t > maxTokens {
                if !cur.isEmpty { pieces.append(cur.joined(separator: " ")); cur = []; curTok = 0 }
                pieces.append(contentsOf: windowWords(sentence, maxTokens: maxTokens, overlapTokens: overlapTokens))
                continue
            }
            if curTok + t > maxTokens, !cur.isEmpty {
                pieces.append(cur.joined(separator: " "))
                // overlap: keep trailing sentences up to overlapTokens
                var overlap: [String] = []
                var oTok = 0
                for s in cur.reversed() {
                    let st = approxTokens(s)
                    if oTok + st > overlapTokens { break }
                    overlap.insert(s, at: 0); oTok += st
                }
                cur = overlap
                curTok = oTok
            }
            cur.append(sentence)
            curTok += t
        }
        if !cur.isEmpty { pieces.append(cur.joined(separator: " ")) }
        return pieces
    }

    /// Last-resort splitter for a single sentence bigger than the cap: fixed word windows with
    /// overlap so every piece fits the token budget (audit D14).
    static func windowWords(_ text: String, maxTokens: Int, overlapTokens: Int) -> [String] {
        let words = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).map(String.init)
        guard !words.isEmpty else { return [] }
        let perWindow = max(1, Int(Double(maxTokens) / 1.33))          // invert approxTokens
        let overlap = min(perWindow - 1, max(0, Int(Double(overlapTokens) / 1.33)))
        let step = max(1, perWindow - overlap)
        var pieces: [String] = []
        var i = 0
        while i < words.count {
            let end = min(i + perWindow, words.count)
            pieces.append(words[i..<end].joined(separator: " "))
            if end == words.count { break }
            i += step
        }
        return pieces
    }

    static func splitSentences(_ text: String) -> [String] {
        var out: [String] = []
        var buf = ""
        for ch in text {
            buf.append(ch)
            if ch == "." || ch == "!" || ch == "?" {
                let trimmed = buf.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { out.append(trimmed) }
                buf = ""
            }
        }
        let tail = buf.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { out.append(tail) }
        return out
    }
}
