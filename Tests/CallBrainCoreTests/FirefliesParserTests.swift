import Testing
import Foundation
@testable import CallBrainCore

@Suite("Fireflies parser")
struct FirefliesParserTests {

    static let sample = """
    {
      "title": "Travis sync — Render GPU pricing",
      "date": 1747238400000,
      "duration": 52.0,
      "participants": ["travis@render.com", "me@company.com"],
      "sentences": [
        {"index": 0, "speaker_name": "Travis", "speaker_id": "0", "text": "On Render, the GPU spot pricing dropped this week.", "start_time": 12.0, "end_time": 18.5},
        {"index": 1, "speaker_name": "Me", "speaker_id": "1", "text": "Good — does that change the validator economics?", "start_time": 18.6, "end_time": 22.0},
        {"index": 2, "speaker_name": "Travis", "speaker_id": "0", "text": "Yeah, materially for inference hardware.", "start_time": 22.1, "end_time": 25.0}
      ]
    }
    """

    @Test("parses sentences, speakers, timestamps and metadata")
    func parsesCore() throws {
        let t = try FirefliesParser.parse(Data(Self.sample.utf8))
        #expect(t.source == .fireflies)
        #expect(t.title == "Travis sync — Render GPU pricing")
        #expect(t.utterances.count == 3)
        #expect(t.speakers == ["Travis", "Me"])               // first-seen order
        #expect(t.durationSeconds == 3120)                    // 52 minutes → seconds
        // epoch-ms date is timezone-independent at the instant level:
        #expect(t.startedAt == Date(timeIntervalSince1970: 1_747_238_400))
        #expect(t.date != nil)

        let u0 = t.utterances[0]
        #expect(u0.speakerRaw == "Travis")
        #expect(u0.tStart == 12.0)
        #expect(u0.tEnd == 18.5)
        #expect(u0.tsConfidence == .exact)
        #expect(u0.isInferredSpeaker == false)                // explicit labels → not inferred
        #expect(u0.speakerConfidence == 1.0)
        #expect(u0.text.hasPrefix("On Render"))
    }

    @Test("empty input throws .empty")
    func emptyThrows() {
        #expect(throws: ParseError.empty) { try FirefliesParser.parse(Data()) }
    }

    @Test("JSON without sentences[] is rejected, not silently accepted")
    func noSentencesThrows() {
        let bad = Data(#"{"title":"x"}"#.utf8)
        #expect(throws: ParseError.self) { try FirefliesParser.parse(bad) }
    }

    @Test("tolerates a payload nested under \"transcript\"")
    func nestedTranscript() throws {
        let nested = """
        {"transcript": {"title": "Nested", "sentences": [
          {"speaker_name": "Max", "text": "Proof of Logits means…", "start_time": 1.0, "end_time": 4.0}
        ]}}
        """
        let t = try FirefliesParser.parse(Data(nested.utf8))
        #expect(t.title == "Nested")
        #expect(t.utterances.count == 1)
        #expect(t.utterances[0].speakerRaw == "Max")
    }
}
