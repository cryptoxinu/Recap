import Testing
import Foundation
@testable import CallBrainCore

@Suite("Chunker")
struct ChunkerTests {

    private func utt(_ seq: Int, _ speaker: String, _ text: String, _ t: Double) -> Utterance {
        Utterance(id: "u_\(seq)", meetingID: "m1", version: 0, seq: seq,
                  speakerRaw: speaker, speakerConfidence: 1.0, tStart: t, tEnd: t + 2,
                  text: text, isInferredSpeaker: false, tsConfidence: .exact)
    }

    @Test("never mixes speakers; packs consecutive same-speaker turns")
    func splitsOnSpeakerChange() {
        let utterances = [
            utt(0, "Riley", "Hello there everyone.", 0),
            utt(1, "Riley", "How are you doing today?", 3),
            utt(2, "Me", "I am doing fine, thanks.", 6),
        ]
        let chunks = Chunker().chunk(utterances)
        #expect(chunks.count == 2)
        #expect(chunks[0].speaker == "Riley")
        #expect(chunks[0].utteranceSeqs == [0, 1])     // both Riley turns packed
        #expect(chunks[0].tStart == 0)
        #expect(chunks[0].tEnd == 5)                    // u1.tEnd = 3 + 2
        #expect(chunks[1].speaker == "Me")
        #expect(chunks[1].utteranceSeqs == [2])
    }

    @Test("splits a monologue that exceeds the hard cap, keeping the same speaker")
    func splitsLongMonologue() {
        let long = String(repeating: "Alpha beta gamma delta epsilon. ", count: 8) // ~40 words, many sentences
        let chunks = Chunker(targetTokens: 8, overlapTokens: 2, maxTokens: 10)
            .chunk([utt(0, "Dom", long, 0)])
        #expect(chunks.count > 1)
        #expect(chunks.allSatisfy { $0.speaker == "Dom" })
        #expect(chunks.allSatisfy { $0.approxTokens <= 14 })   // each piece near the cap (+ small overlap)
    }

    @Test("token estimate scales with word count")
    func approxTokens() {
        #expect(Chunker.approxTokens("one two three") == 4)   // 3 words * 1.33 → ceil 4
        #expect(Chunker.approxTokens("") == 0)
    }

    @Test("a SINGLE unpunctuated sentence over the cap is word-windowed, not emitted oversized (D14)")
    func splitsUnpunctuatedMonologue() {
        // 60 words, ZERO sentence terminators — the old splitLong emitted this whole (> cap).
        let long = (0..<60).map { "word\($0)" }.joined(separator: " ")
        let chunks = Chunker(targetTokens: 8, overlapTokens: 2, maxTokens: 10)
            .chunk([utt(0, "Dom", long, 0)])
        #expect(chunks.count > 1)
        #expect(chunks.allSatisfy { $0.approxTokens <= 12 })   // every piece fits the cap now
        #expect(chunks.allSatisfy { $0.speaker == "Dom" })
    }

    @Test("windowWords covers all words with overlap and never exceeds the cap")
    func windowWordsCoverage() {
        let words = (0..<30).map { "w\($0)" }.joined(separator: " ")
        let pieces = Chunker.windowWords(words, maxTokens: 10, overlapTokens: 3)
        #expect(pieces.count > 1)
        #expect(pieces.allSatisfy { Chunker.approxTokens($0) <= 10 })
        #expect(pieces.first!.contains("w0"))
        #expect(pieces.last!.contains("w29"))     // tail word present → nothing dropped
    }
}
