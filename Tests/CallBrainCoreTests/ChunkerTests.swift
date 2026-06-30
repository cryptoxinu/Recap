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
            utt(0, "Travis", "Hello there everyone.", 0),
            utt(1, "Travis", "How are you doing today?", 3),
            utt(2, "Me", "I am doing fine, thanks.", 6),
        ]
        let chunks = Chunker().chunk(utterances)
        #expect(chunks.count == 2)
        #expect(chunks[0].speaker == "Travis")
        #expect(chunks[0].utteranceSeqs == [0, 1])     // both Travis turns packed
        #expect(chunks[0].tStart == 0)
        #expect(chunks[0].tEnd == 5)                    // u1.tEnd = 3 + 2
        #expect(chunks[1].speaker == "Me")
        #expect(chunks[1].utteranceSeqs == [2])
    }

    @Test("splits a monologue that exceeds the hard cap, keeping the same speaker")
    func splitsLongMonologue() {
        let long = String(repeating: "Alpha beta gamma delta epsilon. ", count: 8) // ~40 words, many sentences
        let chunks = Chunker(targetTokens: 8, overlapTokens: 2, maxTokens: 10)
            .chunk([utt(0, "Max", long, 0)])
        #expect(chunks.count > 1)
        #expect(chunks.allSatisfy { $0.speaker == "Max" })
        #expect(chunks.allSatisfy { $0.approxTokens <= 14 })   // each piece near the cap (+ small overlap)
    }

    @Test("token estimate scales with word count")
    func approxTokens() {
        #expect(Chunker.approxTokens("one two three") == 4)   // 3 words * 1.33 → ceil 4
        #expect(Chunker.approxTokens("") == 0)
    }
}
