import Foundation
import CallBrainCore

/// Read side used by the live-transcript engine (later phase). Lets that engine be unit-tested
/// against a fake source instead of real audio.
public protocol LiveAudioSource: AnyObject, Sendable {
    /// Normalized Float [-1,1] samples for `speaker` from absolute `fromSeconds` up to the newest
    /// retained sample, plus the ACTUAL start-second of the returned slice (== max(fromSeconds,
    /// oldestRetainedSecond)). Returns ([], latestSeconds) when there is nothing new at/after fromSeconds.
    func recent(_ speaker: LiveSpeaker, fromSeconds: Double) -> (samples: [Float], startSeconds: Double)

    /// Newest retained absolute second for `speaker` (0 if the speaker has no audio yet).
    func latestSeconds(_ speaker: LiveSpeaker) -> Double
}

/// Thread-safe dual-speaker ring keyed on a shared capture-clock epoch.
public final class LiveAudioBuffers: LiveAudioSource, @unchecked Sendable {
    private struct SpeakerBuffer {
        var samples: [Int16] = []
        var baseFrame: Int64 = 0
    }

    private static let defaultMaxSeconds = 45.0
    private static let defaultSampleRate = 16_000.0

    private let lock = NSLock()
    private let maxFrames: Int64
    private let sampleRate: Double
    private var epochNanos: UInt64 = 0
    private var you = SpeakerBuffer()
    private var them = SpeakerBuffer()

    public init(maxSeconds: Double = 45, sampleRate: Double = 16_000) {
        let validSampleRate = sampleRate.isFinite && sampleRate > 0 ? sampleRate : Self.defaultSampleRate
        let validMaxSeconds = maxSeconds.isFinite && maxSeconds > 0 ? maxSeconds : Self.defaultMaxSeconds
        self.sampleRate = validSampleRate
        self.maxFrames = Self.frameCount(for: validMaxSeconds, sampleRate: validSampleRate)
    }

    /// Append 16 kHz Int16 mono samples captured at `atNanos` (mach_absolute_time-derived ns, the
    /// SAME clock RecordingWriter uses). Thread-safe (NSLock). The FIRST append across either speaker
    /// sets the shared epoch, so You and Them share one timeline.
    public func append(_ speaker: LiveSpeaker, _ samples: [Int16], atNanos: UInt64) {
        guard !samples.isEmpty else { return }

        lock.withLock {
            if epochNanos == 0 { epochNanos = atNanos }
            let d = Int64(bitPattern: atNanos) &- Int64(bitPattern: epochNanos)
            let startFrame = d > 0 ? Int64(Double(d) / 1e9 * sampleRate) : 0
            withBuffer(for: speaker) { buffer in
                append(samples, atFrame: startFrame, to: &buffer)
            }
        }
    }

    public func recent(_ speaker: LiveSpeaker, fromSeconds: Double) -> (samples: [Float], startSeconds: Double) {
        let slice: (samples: [Int16], startSeconds: Double) = lock.withLock {
            readBuffer(for: speaker) { buffer in
                guard !buffer.samples.isEmpty else { return (samples: [], startSeconds: 0) }
                let tailFrame = buffer.baseFrame + Int64(buffer.samples.count)
                let requestedFrame = frameIndex(forSeconds: fromSeconds)
                guard requestedFrame < tailFrame else { return (samples: [], startSeconds: seconds(forFrame: tailFrame)) }

                let sliceStartFrame = max(requestedFrame, buffer.baseFrame)
                let startOffset = Int(sliceStartFrame - buffer.baseFrame)
                return (
                    samples: Array(buffer.samples[startOffset...]),
                    startSeconds: seconds(forFrame: sliceStartFrame)
                )
            }
        }
        return (slice.samples.map { Float($0) / 32_768 }, slice.startSeconds)
    }

    public func latestSeconds(_ speaker: LiveSpeaker) -> Double {
        lock.withLock {
            readBuffer(for: speaker) { latestSeconds(for: $0) }
        }
    }

    private func append(_ samples: [Int16], atFrame startFrame: Int64, to buffer: inout SpeakerBuffer) {
        guard !buffer.samples.isEmpty else {
            buffer.baseFrame = startFrame
            buffer.samples = samples
            trim(&buffer)
            return
        }

        let tailFrame = buffer.baseFrame + Int64(buffer.samples.count)
        if startFrame >= tailFrame {
            let gap = startFrame - tailFrame
            if gap > maxFrames {
                buffer.baseFrame = startFrame
                buffer.samples = samples
                trim(&buffer)
                return
            }
            if gap > 0 { buffer.samples.append(contentsOf: repeatElement(0, count: Int(gap))) }
            buffer.samples.append(contentsOf: samples)
            trim(&buffer)
            return
        }

        let writeStartFrame = max(startFrame, buffer.baseFrame)
        let sourceOffset = Int(writeStartFrame - startFrame)
        guard sourceOffset < samples.count else { return }

        let localStart = Int(writeStartFrame - buffer.baseFrame)
        let writeCount = samples.count - sourceOffset
        let neededCount = localStart + writeCount
        if buffer.samples.count < neededCount {
            buffer.samples.append(contentsOf: repeatElement(0, count: neededCount - buffer.samples.count))
        }
        for offset in 0..<writeCount {
            buffer.samples[localStart + offset] = samples[sourceOffset + offset]
        }
        trim(&buffer)
    }

    private func trim(_ buffer: inout SpeakerBuffer) {
        let excessFrames = Int64(buffer.samples.count) - maxFrames
        guard excessFrames > 0 else { return }
        buffer.samples.removeFirst(Int(excessFrames))
        buffer.baseFrame += excessFrames
    }

    private func frameIndex(forSeconds seconds: Double) -> Int64 {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        let frames = (seconds * sampleRate).rounded(.up)
        guard frames < Double(Int64.max) else { return Int64.max }
        return Int64(frames)
    }

    private static func frameCount(for seconds: Double, sampleRate: Double) -> Int64 {
        let frames = seconds * sampleRate
        guard frames.isFinite, frames > 0 else { return 1 }
        guard frames < Double(Int64.max) else { return Int64.max }
        return max(1, Int64(frames))
    }

    private func latestSeconds(for buffer: SpeakerBuffer) -> Double {
        guard !buffer.samples.isEmpty else { return 0 }
        return seconds(forFrame: buffer.baseFrame + Int64(buffer.samples.count))
    }

    private func seconds(forFrame frame: Int64) -> Double {
        Double(frame) / sampleRate
    }

    private func readBuffer<T>(for speaker: LiveSpeaker, _ body: (SpeakerBuffer) -> T) -> T {
        switch speaker {
        case .you:
            return body(you)
        case .them:
            return body(them)
        }
    }

    private func withBuffer<T>(for speaker: LiveSpeaker, _ body: (inout SpeakerBuffer) -> T) -> T {
        switch speaker {
        case .you:
            return body(&you)
        case .them:
            return body(&them)
        }
    }
}
