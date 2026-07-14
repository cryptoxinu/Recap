import Testing
import CallBrainCore
@testable import CallBrainAppCore

@Suite("LiveNotesModel")
struct LiveNotesModelTests {
    @MainActor
    @Test("first pass publishes notes even before the growth threshold (empty → non-empty)")
    func testFirstPassPublishes() async {
        let src = StubNotes(passes: [["Decided to ship", "Budget 40k"]])
        var text = "Them: line one. line two."
        let model = LiveNotesModel(source: src, transcript: { text }, minGrowthChars: 10_000)

        await model.refreshIfGrown()

        #expect(model.notes.map(\.text) == ["Decided to ship", "Budget 40k"])
        #expect(model.isWriting == false)
        _ = text   // silence unused-warning on the closure capture
    }

    @MainActor
    @Test("does NOT re-summarize until the transcript grows by the threshold (battery)")
    func testSkipsWhenNotGrown() async {
        let src = StubNotes(passes: [["first"], ["second"]])
        var text = String(repeating: "a", count: 100)
        let model = LiveNotesModel(source: src, transcript: { text }, minGrowthChars: 200)

        await model.refreshIfGrown()          // empty → runs (first pass)
        #expect(model.notes.map(\.text) == ["first"])
        await model.refreshIfGrown()          // grew 0 < 200 → skipped
        #expect(await src.callCount() == 1)

        text += String(repeating: "b", count: 250)   // now grew 250 >= 200
        await model.refreshIfGrown()
        #expect(await src.callCount() == 2)
        #expect(model.notes.map(\.text) == ["second"])
    }

    @MainActor
    @Test("re-summarizes on a large SHRINK too (live source flips You/Them audio → shorter Meet captions)")
    func testResummarizesOnSourceSwitchShrink() async {
        let src = StubNotes(passes: [["from audio"], ["from captions"]])
        // Start on the on-device audio transcript, then flip to the (much shorter) named Meet captions.
        var text = String(repeating: "Them: talk. ", count: 60)   // ~720 chars
        let model = LiveNotesModel(source: src, transcript: { text }, minGrowthChars: 200)

        await model.refreshIfGrown()          // first pass over the audio text
        #expect(model.notes.map(\.text) == ["from audio"])
        #expect(await src.callCount() == 1)

        text = "Alex Rivera: talk."          // source switched → big shrink (~700 → ~18 chars)
        await model.refreshIfGrown()          // must re-summarize despite the length DROP
        #expect(await src.callCount() == 2)
        #expect(model.notes.map(\.text) == ["from captions"])
    }

    @MainActor
    @Test("an empty pass keeps the last good notes (never blanks them)")
    func testEmptyPassKeepsLastNotes() async {
        let src = StubNotes(passes: [["good note"], []])
        var text = "Them: a"
        let model = LiveNotesModel(source: src, transcript: { text }, minGrowthChars: 0)

        await model.refreshIfGrown()
        #expect(model.notes.map(\.text) == ["good note"])
        text += " more"
        await model.refreshIfGrown()          // returns [] → keep the last good notes
        #expect(model.notes.map(\.text) == ["good note"])
    }

    @MainActor
    @Test("drain cancels cleanly and leaves isWriting false")
    func testDrainIsClean() async {
        let src = StubNotes(passes: [["x"]])
        let model = LiveNotesModel(source: src, transcript: { "Them: hi" }, minGrowthChars: 0)
        model.start()
        await model.drain()
        #expect(model.isWriting == false)
    }
}

private actor StubNotes: LiveNotesSource {
    private let passes: [[String]]
    private var calls = 0
    init(passes: [[String]]) { self.passes = passes }

    func summarizeLive(transcript: String, instructions: String) async -> [NoteLine] {
        let i = calls
        calls += 1
        return passes[min(i, passes.count - 1)].map { NoteLine(text: $0, isHeader: false) }
    }

    func callCount() -> Int { calls }
}
