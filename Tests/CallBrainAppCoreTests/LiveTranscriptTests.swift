import Foundation
import Testing
import CallBrainCore
@testable import CallBrainAppCore

@Suite("LiveTranscript")
struct LiveTranscriptTests {
    @MainActor
    @Test("stepOnce publishes interleaved speaker-labeled lines")
    func testStepOncePublishesSpeakerLines() async {
        let source = StubLiveSource(windows: [
            .you: [LiveWindow(samples: Self.samples(), startSeconds: 0, latestSeconds: 5)],
            .them: [LiveWindow(samples: Self.samples(), startSeconds: 0, latestSeconds: 5)],
        ])
        let transcriber = StubTranscriber(responses: [
            [TranscribedSegment(text: "We should ask about validator margins.", tStart: 1, tEnd: 1.4)],
            [TranscribedSegment(text: "The margin changed last week.", tStart: 2, tEnd: 2.5)],
        ])
        let transcript = LiveTranscript(
            source: source,
            transcriber: transcriber,
            tickSeconds: 60,
            stabilitySeconds: 1,
            minWindowSeconds: 1
        )

        await transcript.stepOnce()

        #expect(transcript.lines.map(\.speaker) == [.you, .them])
        #expect(transcript.lines.map(\.text) == [
            "We should ask about validator margins.",
            "The margin changed last week.",
        ])
        #expect(transcript.currentText() == "You: We should ask about validator margins.\nThem: The margin changed last week.")
    }

    @MainActor
    @Test("stepOnce reuses confirmedThrough and the returned window start")
    func testSecondStepUsesConfirmedThroughAndActualWindowStart() async {
        let source = StubLiveSource(windows: [
            .you: [
                LiveWindow(samples: Self.samples(seconds: 3), startSeconds: 0, latestSeconds: 5),
                LiveWindow(samples: Self.samples(seconds: 3), startSeconds: 10, latestSeconds: 14),
            ],
        ])
        let transcriber = StubTranscriber(responses: [
            [TranscribedSegment(text: "First stable line.", tStart: 0, tEnd: 1)],
            [TranscribedSegment(text: "Trimmed-window line.", tStart: 0.25, tEnd: 0.75)],
        ])
        let transcript = LiveTranscript(
            source: source,
            transcriber: transcriber,
            tickSeconds: 60,
            stabilitySeconds: 1,
            minWindowSeconds: 1
        )

        await transcript.stepOnce()
        await transcript.stepOnce()

        #expect(source.requestedFrom(.you).count == 2)
        #expect(approximately(source.requestedFrom(.you)[0], 0))
        #expect(approximately(source.requestedFrom(.you)[1], 1))
        #expect(transcript.lines.map(\.text) == ["First stable line.", "Trimmed-window line."])
        #expect(approximately(transcript.lines[1].tStart, 10.25))
    }

    private static func samples(seconds: Int = 1) -> [Float] {
        Array(repeating: 0.1, count: seconds * 16_000)
    }

    private func approximately(_ lhs: Double, _ rhs: Double, tolerance: Double = 0.000_1) -> Bool {
        abs(lhs - rhs) <= tolerance
    }
}

private struct LiveWindow: Sendable {
    let samples: [Float]
    let startSeconds: Double
    let latestSeconds: Double
}

private final class StubLiveSource: LiveAudioSource, @unchecked Sendable {
    private let lock = NSLock()
    private let windows: [LiveSpeaker: [LiveWindow]]
    private var calls: [LiveSpeaker: Int] = [:]
    private var requests: [LiveSpeaker: [Double]] = [:]

    init(windows: [LiveSpeaker: [LiveWindow]]) {
        self.windows = windows
    }

    func recent(_ speaker: LiveSpeaker, fromSeconds: Double) -> (samples: [Float], startSeconds: Double) {
        lock.withLock {
            let callIndex = calls[speaker, default: 0]
            calls[speaker] = callIndex + 1
            let priorRequests = requests[speaker, default: []]
            requests[speaker] = priorRequests + [fromSeconds]
            guard let speakerWindows = windows[speaker], !speakerWindows.isEmpty else { return ([], 0) }
            let window = speakerWindows[min(callIndex, speakerWindows.count - 1)]
            return (window.samples, window.startSeconds)
        }
    }

    func latestSeconds(_ speaker: LiveSpeaker) -> Double {
        lock.withLock {
            guard let speakerWindows = windows[speaker], !speakerWindows.isEmpty else { return 0 }
            let callIndex = max(0, calls[speaker, default: 0] - 1)
            return speakerWindows[min(callIndex, speakerWindows.count - 1)].latestSeconds
        }
    }

    func requestedFrom(_ speaker: LiveSpeaker) -> [Double] {
        lock.withLock { requests[speaker, default: []] }
    }
}

private actor StubTranscriber: Transcriber {
    nonisolated let modelID = "stub-live"

    private let responses: [[TranscribedSegment]]
    private var index = 0

    init(responses: [[TranscribedSegment]]) {
        self.responses = responses
    }

    func transcribe(_ samples: [Float], progress: @Sendable @escaping (Double) -> Void) async throws -> [TranscribedSegment] {
        progress(1)
        let response = index < responses.count ? responses[index] : []
        index += 1
        return response
    }

    nonisolated func prewarm() async {}
}
