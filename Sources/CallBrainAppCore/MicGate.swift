import Foundation

/// Recorder mic gate state published to the app layer.
public enum MicState: Sendable, Equatable {
    case speaking
    case silent
    case muted
    case off
}

/// One converted 16 kHz mic buffer with the capture timestamp of its first sample.
public struct MicGateBuffer: Sendable, Equatable {
    public let samples: [Int16]
    public let timestampNanos: UInt64

    public init(samples: [Int16], timestampNanos: UInt64) {
        self.samples = samples
        self.timestampNanos = timestampNanos
    }
}

/// Gate output for one mic buffer or control change.
public struct MicGateDecision: Sendable, Equatable {
    public let buffersToEmit: [MicGateBuffer]
    public let state: MicState

    public init(buffersToEmit: [MicGateBuffer], state: MicState) {
        self.buffersToEmit = buffersToEmit
        self.state = state
    }
}

/// Pure mic voice-activity gate. The recorder owns the VAD; this type owns only attack,
/// pre-roll, hangover, force-mute, and disabled-gate transitions.
public struct MicGate: Sendable, Equatable {
    public let gateEnabled: Bool

    private let sampleRate: Int
    private let preRollFrames: Int
    private let hangoverFrames: Int
    private let isOpen: Bool
    private let hangoverFramesRemaining: Int
    private let preRoll: [MicGateBuffer]
    private let preRollFrameCount: Int

    public init(gateEnabled: Bool = true,
                sampleRate: Int = 16_000,
                preRollSeconds: Double = 0.3,
                hangoverSeconds: Double = 0.6) {
        let validSampleRate = sampleRate > 0 ? sampleRate : 16_000
        self.init(
            gateEnabled: gateEnabled,
            sampleRate: validSampleRate,
            preRollFrames: Self.frames(for: preRollSeconds, sampleRate: validSampleRate),
            hangoverFrames: Self.frames(for: hangoverSeconds, sampleRate: validSampleRate),
            isOpen: false,
            hangoverFramesRemaining: 0,
            preRoll: [],
            preRollFrameCount: 0
        )
    }

    private init(gateEnabled: Bool,
                 sampleRate: Int,
                 preRollFrames: Int,
                 hangoverFrames: Int,
                 isOpen: Bool,
                 hangoverFramesRemaining: Int,
                 preRoll: [MicGateBuffer],
                 preRollFrameCount: Int) {
        self.gateEnabled = gateEnabled
        self.sampleRate = sampleRate
        self.preRollFrames = preRollFrames
        self.hangoverFrames = hangoverFrames
        self.isOpen = isOpen
        self.hangoverFramesRemaining = hangoverFramesRemaining
        self.preRoll = preRoll
        self.preRollFrameCount = preRollFrameCount
    }

    public var state: MicState {
        guard gateEnabled else { return .off }
        return isOpen ? .speaking : .silent
    }

    /// Return a copy with the gate flag changed. Existing pre-roll is discarded so toggling the
    /// gate never replays stale closed-gate audio later.
    public func settingGateEnabled(_ enabled: Bool) -> MicGate {
        copy(gateEnabled: enabled, isOpen: false, hangoverFramesRemaining: 0, preRoll: [], preRollFrameCount: 0)
    }

    /// Apply a force-mute or enable-state change without a mic buffer.
    public func control(forceMuted: Bool) -> (gate: MicGate, decision: MicGateDecision) {
        if forceMuted {
            let next = closedWithoutPreRoll()
            return (next, MicGateDecision(buffersToEmit: [], state: .muted))
        }
        if !gateEnabled {
            let next = closedWithoutPreRoll()
            return (next, MicGateDecision(buffersToEmit: [], state: .off))
        }
        let next = copy(isOpen: isOpen, hangoverFramesRemaining: hangoverFramesRemaining)
        return (next, MicGateDecision(buffersToEmit: [], state: next.state))
    }

    /// Process one converted mic buffer. `forceMuted` wins over both VAD and the enabled flag so
    /// externally muted audio is never emitted or retained for pre-roll.
    public func process(_ buffer: MicGateBuffer,
                        isSpeech: Bool,
                        forceMuted: Bool) -> (gate: MicGate, decision: MicGateDecision) {
        guard !buffer.samples.isEmpty else {
            return control(forceMuted: forceMuted)
        }

        if forceMuted {
            let next = closedWithoutPreRoll()
            return (next, MicGateDecision(buffersToEmit: [], state: .muted))
        }

        if !gateEnabled {
            let next = closedWithoutPreRoll()
            return (next, MicGateDecision(buffersToEmit: [buffer], state: .off))
        }

        if isSpeech {
            let next = copy(isOpen: true, hangoverFramesRemaining: hangoverFrames,
                            preRoll: [], preRollFrameCount: 0)
            let replay = isOpen ? [buffer] : preRoll + [buffer]
            return (next, MicGateDecision(buffersToEmit: replay, state: .speaking))
        }

        if isOpen {
            let remaining = hangoverFramesRemaining > 0 ? hangoverFramesRemaining : hangoverFrames
            let nextRemaining = max(0, remaining - buffer.samples.count)
            let nextOpen = nextRemaining > 0
            let next = copy(isOpen: nextOpen, hangoverFramesRemaining: nextRemaining,
                            preRoll: [], preRollFrameCount: 0)
            return (next, MicGateDecision(buffersToEmit: [buffer], state: next.state))
        }

        let retained = retainingPreRoll(buffer)
        let next = copy(preRoll: retained.buffers, preRollFrameCount: retained.frameCount)
        return (next, MicGateDecision(buffersToEmit: [], state: .silent))
    }

    private func retainingPreRoll(_ buffer: MicGateBuffer) -> (buffers: [MicGateBuffer], frameCount: Int) {
        guard preRollFrames > 0 else { return ([], 0) }
        let buffers = preRoll + [buffer]
        let frameCount = preRollFrameCount + buffer.samples.count
        return trimmingPreRoll(buffers, frameCount: frameCount)
    }

    private func trimmingPreRoll(_ buffers: [MicGateBuffer],
                                 frameCount: Int) -> (buffers: [MicGateBuffer], frameCount: Int) {
        guard frameCount > preRollFrames, buffers.count > 1 else { return (buffers, frameCount) }
        let remainingBuffers = Array(buffers.dropFirst())
        let remainingFrameCount = frameCount - buffers[0].samples.count
        return trimmingPreRoll(remainingBuffers, frameCount: remainingFrameCount)
    }

    private func closedWithoutPreRoll() -> MicGate {
        copy(isOpen: false, hangoverFramesRemaining: 0, preRoll: [], preRollFrameCount: 0)
    }

    private func copy(gateEnabled: Bool? = nil,
                      isOpen: Bool? = nil,
                      hangoverFramesRemaining: Int? = nil,
                      preRoll: [MicGateBuffer]? = nil,
                      preRollFrameCount: Int? = nil) -> MicGate {
        MicGate(
            gateEnabled: gateEnabled ?? self.gateEnabled,
            sampleRate: sampleRate,
            preRollFrames: preRollFrames,
            hangoverFrames: hangoverFrames,
            isOpen: isOpen ?? self.isOpen,
            hangoverFramesRemaining: hangoverFramesRemaining ?? self.hangoverFramesRemaining,
            preRoll: preRoll ?? self.preRoll,
            preRollFrameCount: preRollFrameCount ?? self.preRollFrameCount
        )
    }

    private static func frames(for seconds: Double, sampleRate: Int) -> Int {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        let frames = (seconds * Double(sampleRate)).rounded(.toNearestOrAwayFromZero)
        guard frames < Double(Int.max) else { return Int.max }
        return max(0, Int(frames))
    }
}
