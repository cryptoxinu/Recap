import Observation
import CallBrainCore

/// Main-actor owner for rolling live transcription.
///
/// The class owns timing and publication only. The transcript merge rules stay in
/// `LiveTranscriptEngine`, while the injected source/transcriber keep this object fast and
/// deterministic under test.
@MainActor
@Observable
public final class LiveTranscript {
    public private(set) var lines: [LiveLine] = []
    public private(set) var isRunning = false

    private var engine: LiveTranscriptEngine
    private var inFlight = false
    private var loop: Task<Void, Never>?
    private let source: LiveAudioSource
    private let transcriber: Transcriber
    private let tickSeconds: Double
    private let minWindowSeconds: Double

    public init(
        source: LiveAudioSource,
        transcriber: Transcriber,
        tickSeconds: Double = 1.5,
        stabilitySeconds: Double = 2.0,
        minWindowSeconds: Double = 1.0
    ) {
        self.source = source
        self.transcriber = transcriber
        self.tickSeconds = tickSeconds
        self.minWindowSeconds = minWindowSeconds
        self.engine = LiveTranscriptEngine(stabilitySeconds: stabilitySeconds)
    }

    /// Start prewarming the model and begin the fixed-cadence rolling transcript loop.
    public func start() {
        guard !isRunning else { return }
        isRunning = true
        let transcriber = transcriber
        Task { await transcriber.prewarm() }

        let tickSeconds = tickSeconds
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(tickSeconds))
                guard let self, self.isRunning else { return }
                if !self.inFlight { await self.stepOnce() }
            }
        }
    }

    /// Stop future rolling passes while preserving the last published transcript.
    public func stop() {
        loop?.cancel()
        loop = nil
        isRunning = false
    }

    /// Plain speaker-labeled text for the in-call assistant.
    public func currentText() -> String {
        engine.snapshot.plainText
    }

    /// Run exactly one rolling transcription pass. Intended for deterministic tests and the timer loop.
    func stepOnce() async {
        guard !inFlight else { return }
        inFlight = true
        defer { inFlight = false }

        for speaker in [LiveSpeaker.you, .them] {
            let from = engine.confirmedThrough(speaker)
            let (samples, windowStart) = source.recent(speaker, fromSeconds: from)
            guard Double(samples.count) >= minWindowSeconds * 16_000 else { continue }
            let windowEnd = windowStart + Double(samples.count) / 16_000
            let segments = (try? await transcriber.transcribe(samples, progress: { _ in })) ?? []
            let folded = engine.folding(
                speaker,
                segments: segments,
                windowStart: windowStart,
                windowEnd: windowEnd
            )
            engine = folded.engine
        }
        lines = engine.snapshot.lines
    }
}
