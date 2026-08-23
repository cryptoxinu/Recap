import Foundation
import CallBrainAppCore

/// Deterministic pure-Swift sine synthesis + a test-only Goertzel band analyzer for the tone
/// self-test. No hardware, no ML, no FFT in prod — the analyzer lives only in the test target.
///
/// Timeline (all on ONE shared clock, epoch-anchored, exact per-sample mach-ns stamps):
///   [0,1)s  300 Hz  system ("them", isMic:false)  loud
///   [1,2)s  900 Hz  mic    ("me",   isMic:true)   loud
///   [2,3)s  300 Hz  system                         loud
///   [3,4)s  900 Hz  mic                            loud
///   [4,4.5)s 900 Hz mic                            QUIET (RMS ≈ 0.010, just above the 0.008 gate)
/// The two bands never overlap in time, so band ⇒ speaker is unambiguous.
enum SyntheticAudio {
    static let sampleRate: Double = 16_000
    static let chunk = 1_600                     // 0.1 s frames
    /// One sample period in ns at 16 kHz: 1e9 / 16000 = 62_500 exactly (integer, no rounding drift).
    static let nsPerSample: UInt64 = 1_000_000_000 / 16_000
    static let loudAmplitude: Double = 0.3       // RMS ≈ 0.212, far above any floor
    static let quietRMS: Double = 0.010          // just above the 0.008 VAD threshold
}

/// One segment of the timeline, expressed in absolute sample indices at 16 kHz.
private struct ToneSegment {
    let freq: Double
    let isMic: Bool
    let amplitude: Double
    let startSample: Int
    let endSample: Int
}

/// Generate `count` Int16 samples of a sine at `freq`, using the ABSOLUTE sample index so phase is
/// continuous across chunk boundaries and lines up with the decoded timeline the Goertzel reads.
func int16Sine(freq: Double, amplitude: Double, sampleRate: Double, absoluteStart: Int, count: Int) -> [Int16] {
    (0..<count).map { i in
        let n = Double(absoluteStart + i)
        let v = amplitude * sin(2.0 * Double.pi * freq * n / sampleRate)
        return Int16(clamping: Int((v * 32_767.0).rounded()))
    }
}

/// Generate a Float32 sine waveform at `freq` with the given RMS (RMS of a full sine = amplitude/√2).
func floatSine(freq: Double, rms: Double, sampleRate: Double, count: Int) -> [Float] {
    let amplitude = rms * 2.0.squareRoot()
    return (0..<count).map { i in
        Float(amplitude * sin(2.0 * Double.pi * freq * Double(i) / sampleRate))
    }
}

/// A "voiced-like" burst: a sum of in-band formant tones (default F1/F2/F3 ≈ 600/1500/2500 Hz, all
/// inside the ~250–3800 Hz human-voice band), NORMALIZED to an exact target RMS. Used for the W1c
/// acceptance fixture — a QUIET voiced burst (RMS 0.004–0.007, i.e. below the old 0.008 energy floor)
/// the crude `EnergyVADGate` drops but the spectral gate keeps.
func floatVoicedBurst(rms targetRMS: Double, sampleRate: Double, count: Int,
                      formants: [Double] = [600, 1500, 2500]) -> [Float] {
    guard count > 0 else { return [] }
    let raw = (0..<count).map { i -> Double in
        let t = Double(i) / sampleRate
        return formants.reduce(0.0) { $0 + sin(2.0 * Double.pi * $1 * t) }
    }
    let meanSquare = raw.reduce(0.0) { $0 + $1 * $1 } / Double(count)
    let currentRMS = meanSquare.squareRoot()
    let scale = currentRMS > 0 ? targetRMS / currentRMS : 0
    return raw.map { Float($0 * scale) }
}

/// Pull-driven tone source over the fixed timeline. `next()` walks a pre-computed frame list; the
/// cursor is the only mutable state and `drive(_:into:)` pulls it on a single thread, so
/// `@unchecked Sendable` is safe here (test-only, no cross-thread sharing).
final class SineFrameSource: FrameSource, @unchecked Sendable {
    private let frames: [AudioFrames]
    private var cursor = 0

    /// - Parameter epoch: the mach-ns value stamped on the very first sample (frame 0).
    init(epoch: UInt64 = 2_000_000_000) {
        let sr = SyntheticAudio.sampleRate
        let loud = SyntheticAudio.loudAmplitude
        let quietAmp = SyntheticAudio.quietRMS * 2.0.squareRoot()
        let s = Int(sr)   // 1 s = 16000 samples
        let segments: [ToneSegment] = [
            ToneSegment(freq: 300, isMic: false, amplitude: loud,     startSample: 0,       endSample: s),        // [0,1)
            ToneSegment(freq: 900, isMic: true,  amplitude: loud,     startSample: s,       endSample: 2 * s),    // [1,2)
            ToneSegment(freq: 300, isMic: false, amplitude: loud,     startSample: 2 * s,   endSample: 3 * s),    // [2,3)
            ToneSegment(freq: 900, isMic: true,  amplitude: loud,     startSample: 3 * s,   endSample: 4 * s),    // [3,4)
            ToneSegment(freq: 900, isMic: true,  amplitude: quietAmp, startSample: 4 * s,   endSample: 4 * s + s / 2), // [4,4.5)
        ]
        var built: [AudioFrames] = []
        for seg in segments {
            var start = seg.startSample
            while start < seg.endSample {
                let count = min(SyntheticAudio.chunk, seg.endSample - start)
                let samples = int16Sine(freq: seg.freq, amplitude: seg.amplitude,
                                        sampleRate: sr, absoluteStart: start, count: count)
                let stamp = epoch + UInt64(start) * SyntheticAudio.nsPerSample
                built.append(AudioFrames(samples: samples, hostTimeNanos: stamp, isMic: seg.isMic))
                start += count
            }
        }
        frames = built
    }

    func next() -> AudioFrames? {
        guard cursor < frames.count else { return nil }
        defer { cursor += 1 }
        return frames[cursor]
    }
}

/// Test-only Goertzel single-frequency magnitude over a time window [start,end) in seconds. Keeps a
/// full FFT out of the prod code — we only ever probe two known tone frequencies.
enum Goertzel {
    static func magnitude(_ samples: [Float], freq: Double, sampleRate: Double, in window: Range<Double>) -> Double {
        let startIdx = max(0, Int((window.lowerBound * sampleRate).rounded()))
        let endIdx = min(samples.count, Int((window.upperBound * sampleRate).rounded()))
        guard endIdx > startIdx else { return 0 }
        let n = endIdx - startIdx
        let omega = 2.0 * Double.pi * freq / sampleRate
        let coeff = 2.0 * cos(omega)
        var s1 = 0.0, s2 = 0.0
        for i in startIdx..<endIdx {
            let s0 = Double(samples[i]) + coeff * s1 - s2
            s2 = s1
            s1 = s0
        }
        let power = s1 * s1 + s2 * s2 - coeff * s1 * s2
        return (max(0, power)).squareRoot() / Double(n)   // normalize by window length
    }

    /// True when `target`-Hz energy dominates `rival`-Hz energy by at least `ratio×` in the window.
    static func bandDominates(_ samples: [Float], target: Double, over rival: Double,
                              sampleRate: Double, in window: Range<Double>, ratio: Double = 4.0) -> Bool {
        let t = magnitude(samples, freq: target, sampleRate: sampleRate, in: window)
        let r = magnitude(samples, freq: rival, sampleRate: sampleRate, in: window)
        return t > r * ratio
    }
}
