import Testing
import Foundation
@testable import CallBrainCore

@Suite("Fireflies copy parser (real free-tier format)")
struct FirefliesCopyParserTests {

    // Shape taken from a real Fireflies copy-paste: "Speaker Name: H:MM:SS" then the text.
    static let sample = """
    Zade Kal: 00:00
     Max.

    Maxwell Lang: 00:04
     Hey, how's it going? I just wanted to loop you in because this is like a partnership.

    Travis Good: 04:09
     Yeah, we just need to come under the open router pricing that we're currently at.

    Maxwell Lang: 01:00:28
     Yeah, but I assume that what they think is okay.
    """

    @Test("parses Name: H:MM:SS headers, multi-segment timestamps, and turn order")
    func parsesCore() throws {
        let t = try FirefliesCopyParser.parse(Self.sample)
        #expect(t.source == .fireflies)
        #expect(t.speakers == ["Zade Kal", "Maxwell Lang", "Travis Good"])
        #expect(t.utterances.count == 4)
        #expect(t.utterances[0].speakerRaw == "Zade Kal")
        #expect(t.utterances[0].tStart == 0)
        #expect(t.utterances[2].speakerRaw == "Travis Good")
        #expect(t.utterances[2].tStart == 249)        // 04:09 = 4*60+9
        #expect(t.utterances[3].tStart == 3628)       // 01:00:28 = 3600+28
        #expect(t.utterances.allSatisfy { $0.tsConfidence == .exact })
        #expect(t.utterances[0].text == "Max.")
    }

    @Test("empty input throws .empty")
    func empty() {
        #expect(throws: ParseError.empty) { try FirefliesCopyParser.parse("  \n  ") }
    }

    @Test("a body line containing a stray colon-time is not a false header")
    func noFalseHeader() throws {
        let tricky = """
        Maxwell Lang: 00:00
         I said meet at 5:00 but the ratio was 4:14 last time.

        Zade Kal: 00:30
         Got it.
        """
        let t = try FirefliesCopyParser.parse(tricky)
        #expect(t.utterances.count == 2)                          // not split on "5:00"/"4:14"
        #expect(t.utterances[0].text.contains("4:14 last time"))
    }
}
