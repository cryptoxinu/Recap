import Foundation

/// Pure energy-based voice-activity detector — a faithful mirror of WhisperKit's `EnergyVAD`
/// (0.1 s RMS frames, threshold 0.008) with NO WhisperKit / CoreML dependency, so the record
/// path is unit-testable and `CallBrainAppCore` never links WhisperKit.
///
/// Extracted verbatim from the `energyVoiceActivity`/`rmsEnergy` fallback that already shipped
/// inside `AudioCapture.RecordingWriter`; the algorithm, 0.1 s frame length, and 0.008 threshold
/// are unchanged. WhisperKit's `EnergyVAD.voiceActivity` computes the same per-frame RMS (via
/// `vDSP_rmsqv`) compared against the same threshold, so this is behaviourally equivalent to the
/// prod path to within floating-point summation order.
public struct EnergyVADGate: Sendable {
    public let sampleRate: Int
    public let energyThreshold: Float
    private let frameLengthSamples: Int

    public init(sampleRate: Int = 16_000, energyThreshold: Float = 0.008) {
        let validSampleRate = sampleRate > 0 ? sampleRate : 16_000
        self.sampleRate = validSampleRate
        self.energyThreshold = energyThreshold
        // 0.1 s frame, matching WhisperKit EnergyVAD's default frameLength (0.1 s * 16 kHz = 1600).
        self.frameLengthSamples = max(1, Int(0.1 * Double(validSampleRate)))
    }

    /// Per-frame speech mask: `true` where a 0.1 s RMS frame exceeds the energy threshold. Empty
    /// input (or a degenerate frame length) yields an empty mask, so a caller's `.contains(true)`
    /// reads as "no speech".
    public func voiceActivity(in waveform: [Float]) -> [Bool] {
        guard !waveform.isEmpty, frameLengthSamples > 0 else { return [] }
        let frameCount = Int((Double(waveform.count) / Double(frameLengthSamples)).rounded(.up))
        return (0..<frameCount).map { frameIndex in
            let start = frameIndex * frameLengthSamples
            let end = min(start + frameLengthSamples, waveform.count)
            return Self.rmsEnergy(waveform[start..<end]) > energyThreshold
        }
    }

    static func rmsEnergy(_ samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(Float(0)) { partial, sample in partial + sample * sample }
        return sqrt(sum / Float(samples.count))
    }
}
