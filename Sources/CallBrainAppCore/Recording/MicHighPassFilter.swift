import Foundation

/// A stable 2nd-order Butterworth high-pass biquad applied to the MIC float samples ONLY (before
/// Int16 conversion / resampling), to strip sub-~80 Hz DC offset, room rumble, and handling noise
/// that muddies a call recording. NEVER applied to the system audio (the other participants).
///
/// State (`z1`/`z2`) is carried ACROSS buffers so there is no per-buffer transient — feeding the
/// same signal as one buffer or many small buffers yields the same steady-state output, and there
/// is no click at chunk boundaries (the task's "carry filter state" requirement).
///
/// Coefficients: RBJ audio-EQ-cookbook high-pass with Q = 1/√2 (Butterworth — maximally flat
/// passband), cutoff `fc` = 80 Hz at the mic's native sample rate `fs`:
///   w0    = 2π·fc/fs
///   alpha = sin(w0) / (2·Q)
///   b0 =  (1 + cos w0)/2,  b1 = -(1 + cos w0),  b2 = (1 + cos w0)/2
///   a0 =  1 + alpha,       a1 = -2 cos w0,       a2 = 1 - alpha       (all divided by a0)
/// A first-order DC blocker would give only −6 dB/oct; this 2nd-order section gives −12 dB/oct, so
/// the 900 Hz mic self-test tone (≈11× the cutoff) passes essentially untouched while 40 Hz
/// (½ the cutoff) is attenuated ≈ −12 dB. Runs as a Transposed Direct-Form-II biquad in Double for
/// numerical stability; the input array is never mutated (a fresh output array is returned) — only
/// the filter's own z-state advances.
public struct MicHighPassFilter: Sendable {
    /// Default corner frequency. Documented + tunable in one place.
    public static let cutoffHz: Double = 80

    private let b0: Double
    private let b1: Double
    private let b2: Double
    private let a1: Double
    private let a2: Double
    private var z1: Double = 0
    private var z2: Double = 0

    public init(sampleRate: Double, cutoffHz: Double = MicHighPassFilter.cutoffHz) {
        let fs = sampleRate > 0 ? sampleRate : 16_000
        let w0 = 2.0 * Double.pi * cutoffHz / fs
        let cosw0 = cos(w0)
        let sinw0 = sin(w0)
        let q = 1.0 / 2.0.squareRoot()          // Butterworth
        let alpha = sinw0 / (2.0 * q)
        let a0 = 1.0 + alpha
        self.b0 = ((1.0 + cosw0) / 2.0) / a0
        self.b1 = (-(1.0 + cosw0)) / a0
        self.b2 = ((1.0 + cosw0) / 2.0) / a0
        self.a1 = (-2.0 * cosw0) / a0
        self.a2 = (1.0 - alpha) / a0
    }

    /// High-pass `input`, carrying z-state across calls. Immutable input → new output array.
    public mutating func process(_ input: [Float]) -> [Float] {
        guard !input.isEmpty else { return input }
        var out = [Float](repeating: 0, count: input.count)
        var s1 = z1
        var s2 = z2
        for i in 0..<input.count {
            let x = Double(input[i])
            let y = b0 * x + s1                  // Transposed Direct Form II
            s1 = b1 * x - a1 * y + s2
            s2 = b2 * x - a2 * y
            out[i] = Float(y)
        }
        z1 = s1
        z2 = s2
        return out
    }
}
