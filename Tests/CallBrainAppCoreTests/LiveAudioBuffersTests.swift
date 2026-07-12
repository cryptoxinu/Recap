import Testing
@testable import CallBrainAppCore

@Suite("LiveAudioBuffers")
struct LiveAudioBuffersTests {
    private let epoch: UInt64 = 1_000_000_000

    @Test("append then recent returns normalized samples from zero")
    func testAppendThenRecentNormalizesSamples() {
        let buffers = LiveAudioBuffers()
        buffers.append(.you, [0, 16_384, -16_384], atNanos: epoch)

        let slice = buffers.recent(.you, fromSeconds: 0)

        #expect(slice.samples.count == 3)
        #expect(approximately(slice.startSeconds, 0))
        #expect(approximately(slice.samples[0], 0))
        #expect(approximately(slice.samples[1], 0.5))
        #expect(approximately(slice.samples[2], -0.5))
    }

    @Test("speaker buffers share the first capture epoch")
    func testSharedEpochAcrossSpeakers() {
        let buffers = LiveAudioBuffers()
        buffers.append(.you, [1], atNanos: epoch)
        buffers.append(.them, [2], atNanos: nanos(after: 1))

        let slice = buffers.recent(.them, fromSeconds: 0)

        #expect(slice.samples.count == 1)
        #expect(approximately(slice.startSeconds, 1))
    }

    @Test("reading at latest returns an empty slice")
    func testRecentFromLatestReturnsEmptySamples() {
        let buffers = LiveAudioBuffers()
        buffers.append(.you, [1, 2, 3], atNanos: epoch)

        let latest = buffers.latestSeconds(.you)
        let slice = buffers.recent(.you, fromSeconds: latest)

        #expect(slice.samples.isEmpty)
        #expect(approximately(slice.startSeconds, latest))
    }

    @Test("trim drops old audio while latest keeps growing")
    func testTrimAdvancesOldestRetainedSecond() {
        let buffers = LiveAudioBuffers(maxSeconds: 1, sampleRate: 4)
        buffers.append(.you, [1, 2, 3, 4, 5, 6], atNanos: epoch)

        let slice = buffers.recent(.you, fromSeconds: 0)

        #expect(slice.samples.count == 4)
        #expect(approximately(slice.startSeconds, 0.5))
        #expect(approximately(buffers.latestSeconds(.you), 1.5))
        #expect(approximately(slice.samples[0], Float(3) / 32_768))
    }

    @Test("latest grows with appended duration")
    func testLatestSecondsGrowsWithDuration() {
        let buffers = LiveAudioBuffers(maxSeconds: 10, sampleRate: 4)
        buffers.append(.you, [1, 2], atNanos: epoch)

        #expect(approximately(buffers.latestSeconds(.you), 0.5))

        buffers.append(.you, [3, 4], atNanos: nanos(after: 0.5))

        #expect(approximately(buffers.latestSeconds(.you), 1))
    }

    @Test("fractional recent start does not rewind before requested second")
    func testRecentFractionalStartDoesNotRewindBeforeRequestedSecond() {
        let buffers = LiveAudioBuffers(maxSeconds: 10, sampleRate: 16_000)
        let fromSeconds = 0.30007
        buffers.append(.you, Array(repeating: Int16(1), count: 48_000), atNanos: epoch)

        let slice = buffers.recent(.you, fromSeconds: fromSeconds)

        #expect(!slice.samples.isEmpty)
        #expect(slice.startSeconds >= fromSeconds)
    }

    private func nanos(after seconds: Double) -> UInt64 {
        epoch + UInt64(seconds * 1_000_000_000)
    }

    private func approximately(_ lhs: Double, _ rhs: Double, tolerance: Double = 0.000_1) -> Bool {
        abs(lhs - rhs) <= tolerance
    }

    private func approximately(_ lhs: Float, _ rhs: Float, tolerance: Float = 0.000_1) -> Bool {
        abs(lhs - rhs) <= tolerance
    }
}
