import Testing
import Foundation
@testable import CallBrainCore

@Suite("Fathom parser")
struct FathomParserTests {

    static let sample = """
    Travis <> Render sync
    https://fathom.video/share/abc123
    Travis  0:12
    On Render, the GPU spot pricing dropped this week.
    Me  0:18
    Good, does that change the validator economics?
    Travis  0:22
    Yeah, materially for inference hardware. We should follow up with Max.
    """

    @Test("parses title, speaker blocks and timecodes")
    func parsesCore() throws {
        let t = try FathomParser.parse(Self.sample)
        #expect(t.source == .fathom)
        #expect(t.title == "Travis <> Render sync")
        #expect(t.speakers == ["Travis", "Me"])
        #expect(t.utterances.count == 3)

        let u0 = t.utterances[0]
        #expect(u0.speakerRaw == "Travis")
        #expect(u0.tStart == 12.0)                 // 0:12
        #expect(u0.tEnd == 18.0)                   // derived from next turn's start (0:18)
        #expect(u0.text == "On Render, the GPU spot pricing dropped this week.")
        #expect(u0.tsConfidence == .exact)

        // last turn: tEnd falls back to its own start (no following turn)
        #expect(t.utterances[2].tStart == 22.0)
        #expect(t.utterances[2].tEnd == 22.0)
        #expect(t.utterances[2].text.contains("inference hardware"))
    }

    @Test("a body line ending in a timecode is NOT mistaken for a speaker header")
    func noFalseHeaderFromTrailingTimecode() throws {
        let tricky = """
        Travis  0:00
        Let's sync again, maybe meet by 5:00 tomorrow to confirm.
        Me  0:30
        Works for me.
        """
        let t = try FathomParser.parse(tricky)
        #expect(t.utterances.count == 2)                         // not 3
        #expect(t.utterances[0].text.contains("meet by 5:00"))   // stayed body text
        #expect(t.speakers == ["Travis", "Me"])
    }

    @Test("empty input throws .empty")
    func emptyThrows() {
        #expect(throws: ParseError.empty) { try FathomParser.parse("   \n  ") }
    }
}
