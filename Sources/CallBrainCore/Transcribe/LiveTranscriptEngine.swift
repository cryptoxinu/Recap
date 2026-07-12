import Foundation

/// One line in the rolling live transcript, already labeled with its live speaker stream.
public struct LiveLine: Sendable, Equatable, Identifiable {
    /// Stable identity derived from speaker + absolute start time rounded to milliseconds.
    public let id: String
    /// Speaker stream that produced this text.
    public let speaker: LiveSpeaker
    /// Trimmed transcript text for this span.
    public let text: String
    /// Absolute start time in seconds since recording start.
    public let tStart: Double
    /// Absolute end time in seconds since recording start.
    public let tEnd: Double
    /// True once the line is outside the rolling model tail and should no longer change.
    public let confirmed: Bool

    public init(speaker: LiveSpeaker, text: String, tStart: Double, tEnd: Double, confirmed: Bool) {
        self.id = "\(speaker.rawValue)#\(Int((tStart * 1000).rounded()))"
        self.speaker = speaker
        self.text = text
        self.tStart = tStart
        self.tEnd = tEnd
        self.confirmed = confirmed
    }
}

/// Read model published by the live transcript reducer.
public struct LiveTranscriptSnapshot: Sendable, Equatable {
    /// Confirmed lines plus the current unconfirmed tails, interleaved by timeline.
    public let lines: [LiveLine]
    /// Plain speaker-labeled transcript in the same order as `lines`.
    public let plainText: String

    public init(lines: [LiveLine], plainText: String) {
        self.lines = lines
        self.plainText = plainText
    }
}

/// Pure rolling transcript reducer.
///
/// The caller owns the returned copy after each fold. The engine stores only deterministic speaker
/// state: append-only confirmed lines, the latest unconfirmed tail, and the per-speaker confirmed
/// frontier used to request the next audio window.
public struct LiveTranscriptEngine: Sendable, Equatable {
    private struct SpeakerState: Sendable, Equatable {
        let confirmed: [LiveLine]
        let unconfirmed: [LiveLine]
        let confirmedThrough: Double

        static let empty = SpeakerState(confirmed: [], unconfirmed: [], confirmedThrough: 0)
    }

    private static let dedupeTolerance = 0.000_001

    private let stabilitySeconds: Double
    private let speakerStates: [LiveSpeaker: SpeakerState]

    public init(stabilitySeconds: Double = 2.0) {
        self.stabilitySeconds = stabilitySeconds
        self.speakerStates = [:]
    }

    private init(stabilitySeconds: Double, speakerStates: [LiveSpeaker: SpeakerState]) {
        self.stabilitySeconds = stabilitySeconds
        self.speakerStates = speakerStates
    }

    /// Fold one speaker's freshly transcribed rolling window into a new engine copy.
    ///
    /// - Parameters:
    ///   - speaker: Speaker stream whose window was transcribed.
    ///   - segments: Model-relative transcript spans for the provided audio samples.
    ///   - windowStart: Actual absolute start-second returned by `LiveAudioSource.recent`.
    ///   - windowEnd: Newest retained absolute second at grab time.
    /// - Returns: The updated reducer and the speaker's new confirmed frontier.
    public func folding(
        _ speaker: LiveSpeaker,
        segments: [TranscribedSegment],
        windowStart: Double,
        windowEnd: Double
    ) -> (engine: LiveTranscriptEngine, confirmedThrough: Double) {
        let prior = speakerStates[speaker] ?? .empty
        let stableBoundary = windowEnd - stabilitySeconds
        let normalized = segments.compactMap { segment -> LiveLine? in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let absStart = windowStart + segment.tStart
            let absEnd = windowStart + segment.tEnd
            return LiveLine(speaker: speaker, text: text, tStart: absStart, tEnd: absEnd, confirmed: absEnd <= stableBoundary)
        }.sorted { lhs, rhs in
            if lhs.tStart != rhs.tStart { return lhs.tStart < rhs.tStart }
            return lhs.tEnd < rhs.tEnd
        }

        let newlyConfirmed = normalized.filter {
            $0.confirmed && $0.tStart >= prior.confirmedThrough - Self.dedupeTolerance
        }
        let currentTail = normalized.filter { !$0.confirmed }.map {
            LiveLine(speaker: $0.speaker, text: $0.text, tStart: $0.tStart, tEnd: $0.tEnd, confirmed: false)
        }
        let newConfirmedThrough = newlyConfirmed.reduce(prior.confirmedThrough) { max($0, $1.tEnd) }
        let nextState = SpeakerState(
            confirmed: prior.confirmed + newlyConfirmed,
            unconfirmed: currentTail,
            confirmedThrough: newConfirmedThrough
        )
        let nextStates = speakerStates.merging([speaker: nextState]) { _, new in new }
        let next = LiveTranscriptEngine(stabilitySeconds: stabilitySeconds, speakerStates: nextStates)
        return (next, newConfirmedThrough)
    }

    /// Absolute second through which `speaker` has stable committed text.
    public func confirmedThrough(_ speaker: LiveSpeaker) -> Double {
        (speakerStates[speaker] ?? .empty).confirmedThrough
    }

    /// Current interleaved confirmed + unconfirmed transcript.
    public var snapshot: LiveTranscriptSnapshot {
        let unordered = LiveSpeaker.allCases.flatMap { speaker in
            let state = speakerStates[speaker] ?? .empty
            return state.confirmed + state.unconfirmed
        }
        let ordered = Self.ordered(unordered)
        let text = ordered.map { "\($0.speaker.rawValue): \($0.text)" }.joined(separator: "\n")
        return LiveTranscriptSnapshot(lines: ordered, plainText: text)
    }

    private static func ordered(_ lines: [LiveLine]) -> [LiveLine] {
        lines.enumerated().sorted { lhs, rhs in
            if lhs.element.tStart != rhs.element.tStart {
                return lhs.element.tStart < rhs.element.tStart
            }
            let leftSpeaker = speakerOrder(lhs.element.speaker)
            let rightSpeaker = speakerOrder(rhs.element.speaker)
            if leftSpeaker != rightSpeaker { return leftSpeaker < rightSpeaker }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    private static func speakerOrder(_ speaker: LiveSpeaker) -> Int {
        switch speaker {
        case .you:
            return 0
        case .them:
            return 1
        }
    }
}
