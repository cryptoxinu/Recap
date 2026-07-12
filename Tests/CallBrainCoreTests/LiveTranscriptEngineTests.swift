import Testing
@testable import CallBrainCore

@Suite("LiveTranscriptEngine")
struct LiveTranscriptEngineTests {
    @Test("stability boundary separates confirmed lines from trailing tail")
    func testConfirmedVsUnconfirmedBoundary() {
        let engine = LiveTranscriptEngine(stabilitySeconds: 2)
        let folded = engine.folding(
            .them,
            segments: [
                TranscribedSegment(text: "Already stable.", tStart: 1, tEnd: 7.5),
                TranscribedSegment(text: "Still changing.", tStart: 8.2, tEnd: 9.4),
            ],
            windowStart: 0,
            windowEnd: 10
        )

        let lines = folded.engine.snapshot.lines

        #expect(lines.count == 2)
        #expect(lines[0].text == "Already stable.")
        #expect(lines[0].confirmed)
        #expect(lines[1].text == "Still changing.")
        #expect(!lines[1].confirmed)
        #expect(approximately(folded.confirmedThrough, 7.5))
        #expect(approximately(folded.engine.confirmedThrough(.them), 7.5))
    }

    @Test("window start offsets model-relative segment times")
    func testAbsoluteTimeOffset() {
        let folded = LiveTranscriptEngine(stabilitySeconds: 2).folding(
            .you,
            segments: [TranscribedSegment(text: "Offset line.", tStart: 0.5, tEnd: 1.2)],
            windowStart: 10,
            windowEnd: 20
        )

        let line = folded.engine.snapshot.lines[0]

        #expect(approximately(line.tStart, 10.5))
        #expect(approximately(line.tEnd, 11.2))
    }

    @Test("snapshot interleaves speakers and builds speaker labels")
    func testInterleaveAndLabels() {
        let afterYou = LiveTranscriptEngine(stabilitySeconds: 2).folding(
            .you,
            segments: [TranscribedSegment(text: "We should revisit pricing.", tStart: 1.0, tEnd: 1.5)],
            windowStart: 0,
            windowEnd: 10
        ).engine
        let engine = afterYou.folding(
            .them,
            segments: [TranscribedSegment(text: "Agreed.", tStart: 2.0, tEnd: 2.4)],
            windowStart: 0,
            windowEnd: 10
        ).engine

        let snapshot = engine.snapshot

        #expect(snapshot.lines.map(\.speaker) == [.you, .them])
        #expect(approximately(snapshot.lines[0].tStart, 1.0))
        #expect(approximately(snapshot.lines[1].tStart, 2.0))
        #expect(snapshot.plainText == "You: We should revisit pricing.\nThem: Agreed.")
    }

    @Test("folding the same confirmed segment twice does not double commit")
    func testDedupeConfirmedSegments() {
        let segment = TranscribedSegment(text: "Stable once.", tStart: 0, tEnd: 1)
        let once = LiveTranscriptEngine(stabilitySeconds: 2).folding(
            .you,
            segments: [segment],
            windowStart: 0,
            windowEnd: 10
        ).engine
        let twice = once.folding(
            .you,
            segments: [segment],
            windowStart: 0,
            windowEnd: 10
        ).engine

        #expect(twice.snapshot.lines.count == 1)
        #expect(twice.snapshot.lines[0].text == "Stable once.")
        #expect(approximately(twice.confirmedThrough(.you), 1))
    }

    @Test("empty fold clears unconfirmed tail and keeps confirmed lines")
    func testEmptyFoldClearsTailOnly() {
        let engine = LiveTranscriptEngine(stabilitySeconds: 2).folding(
            .them,
            segments: [
                TranscribedSegment(text: "Keep me.", tStart: 0, tEnd: 1),
                TranscribedSegment(text: "Drop tail.", tStart: 4, tEnd: 4.8),
            ],
            windowStart: 0,
            windowEnd: 5
        ).engine

        let folded = engine.folding(.them, segments: [], windowStart: 1, windowEnd: 5).engine
        let lines = folded.snapshot.lines

        #expect(lines.count == 1)
        #expect(lines[0].text == "Keep me.")
        #expect(lines[0].confirmed)
        #expect(approximately(folded.confirmedThrough(.them), 1))
    }

    private func approximately(_ lhs: Double, _ rhs: Double, tolerance: Double = 0.000_1) -> Bool {
        abs(lhs - rhs) <= tolerance
    }
}
