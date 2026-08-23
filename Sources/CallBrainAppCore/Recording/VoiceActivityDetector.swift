import Foundation
import Accelerate

/// The synchronous, per-flush-window speech test the recorder's mic gate consumes. One
/// `[Float] -> [Bool]` call on the mix serial queue: `.contains(true)` ⇒ this window carried voice.
///
/// Kept deliberately minimal and matching the shipped `EnergyVADGate` contract so the primary
/// detector is a drop-in and the fallback path can never regress. Implementations MUST be pure and
/// non-blocking (they run on `AudioMixWriter`'s serial queue between audio buffers) and `Sendable`.
///
/// Normalization: `waveform` is Float PCM in roughly [-1, 1] (the writer passes `Int16 / 32768`).
/// Empty input yields an empty mask so a caller's `.contains(true)` reads as "no speech".
public protocol VoiceActivityDetector: Sendable {
    /// Per-frame speech mask over `waveform`, one `Bool` per ~0.1 s frame.
    func voiceActivity(in waveform: [Float]) -> [Bool]
}

/// The shipped 0.008-RMS energy gate is the guaranteed FALLBACK detector — it can never drop quiet
/// speech that a lower-floor primary already kept, and OR-ing it in guarantees the recorder is never
/// LESS permissive than the behaviour that shipped.
extension EnergyVADGate: VoiceActivityDetector {}

/// Improved, low-latency voice-activity gate that fixes the founder's complaint — the crude single
/// 0.008 RMS threshold dropped QUIET speech. It stays synchronous and framework-light (Accelerate
/// `vDSP` only — no WhisperKit, no CoreML, no SoundAnalysis latency), so it slots into the existing
/// per-buffer `[Float] -> [Bool]` call on the mix serial queue with NO thread hop and NO onset lag.
///
/// Why not Apple `SoundAnalysis`? `SNClassifySoundRequest`'s built-in classifier only supports
/// analysis windows of **0.5 s … 15 s** (`windowDurationConstraint`); even at its 0.5 s minimum a
/// speech verdict trails the audio by half a second, which would clip word onsets in a per-buffer
/// mic gate. A spectral energy gate decides on the CURRENT ~0.1 s frame, so onsets survive.
///
/// The fix, per frame (0.1 s):
///   1. RMS ≤ `noiseFloor`            → definitively silence (the only always-safe reject).
///   2. RMS ≥ `onsetFloor` (0.008)    → loud → always speech. This is exactly the old gate, so the
///                                      detector is a strict SUPERSET of `EnergyVADGate(0.008)` —
///                                      nothing the shipped gate kept is ever newly dropped.
///   3. otherwise QUIET: keep it ONLY when it looks VOICED — a `vDSP` FFT band-energy ratio proves
///      most energy sits in the human voice band (~250–3800 Hz). This lets the floor drop to
///      `voiceFloor` (0.003) to catch the founder's soft speech WITHOUT also passing 60 Hz mains
///      hum / low rumble / room tone (all out-of-band → rejected). Intra-window hysteresis holds an
///      already-open frame at the lower `keepFloor` so a mid-word dip isn't chopped.
///
/// Bias is always toward recording: the only rejections are true silence and low-energy non-voice.
public struct SpectralVADGate: VoiceActivityDetector, Sendable {
    public let sampleRate: Int
    private let frameLengthSamples: Int

    // Energy floors (RMS of Float PCM in [-1, 1]).
    private let noiseFloor: Float   // below this → silence, hard reject
    private let keepFloor: Float    // hysteresis: once open, hold at this lower floor
    private let voiceFloor: Float   // a VOICED quiet frame at/above this opens the gate
    private let onsetFloor: Float   // loud → always speech (== the shipped EnergyVADGate threshold)

    // Spectral voicing measure (vDSP FFT).
    private let voiceBandRatioThreshold: Float
    private let voiceLowHz: Float
    private let voiceHighHz: Float
    private let analysisLowHz: Float
    private let analysisHighHz: Float
    private let fftLog2: vDSP_Length
    private let fftSize: Int

    public init(sampleRate: Int = 16_000,
                noiseFloor: Float = 0.0012,
                keepFloor: Float = 0.0022,
                voiceFloor: Float = 0.0030,
                onsetFloor: Float = 0.0080,
                voiceBandRatioThreshold: Float = 0.40,
                voiceLowHz: Float = 250,
                voiceHighHz: Float = 3_800,
                analysisLowHz: Float = 50,
                analysisHighHz: Float = 8_000) {
        let validSampleRate = sampleRate > 0 ? sampleRate : 16_000
        self.sampleRate = validSampleRate
        // 0.1 s frame — the same granularity as EnergyVADGate so the two masks are interchangeable.
        self.frameLengthSamples = max(1, Int(0.1 * Double(validSampleRate)))
        self.noiseFloor = noiseFloor
        self.keepFloor = keepFloor
        self.voiceFloor = voiceFloor
        self.onsetFloor = onsetFloor
        self.voiceBandRatioThreshold = voiceBandRatioThreshold
        self.voiceLowHz = voiceLowHz
        self.voiceHighHz = voiceHighHz
        self.analysisLowHz = analysisLowHz
        self.analysisHighHz = analysisHighHz
        // Next power of two ≥ the 0.1 s frame (1600 @16k → 2048) for the real FFT; zero-padded.
        var log2 = vDSP_Length(1)
        while (1 << log2) < self.frameLengthSamples { log2 += 1 }
        self.fftLog2 = log2
        self.fftSize = 1 << log2
    }

    public func voiceActivity(in waveform: [Float]) -> [Bool] {
        guard !waveform.isEmpty, frameLengthSamples > 0 else { return [] }
        let frameCount = Int((Double(waveform.count) / Double(frameLengthSamples)).rounded(.up))
        // One FFT setup reused across every frame in THIS call (created locally → the struct stays a
        // pure, immutable, Sendable value; no cross-call mutable state, no per-frame allocation).
        let setup = vDSP_create_fftsetup(fftLog2, FFTRadix(kFFTRadix2))
        defer { if let setup { vDSP_destroy_fftsetup(setup) } }

        var open = false
        return (0..<frameCount).map { frameIndex in
            let start = frameIndex * frameLengthSamples
            let end = min(start + frameLengthSamples, waveform.count)
            let frame = waveform[start..<end]
            let rms = Self.rms(frame)

            // 1. True silence — the only always-safe rejection.
            if rms <= noiseFloor { open = false; return false }
            // 2. Loud → always record (record-when-unsure). Strict superset of EnergyVADGate(0.008).
            if rms >= onsetFloor { open = true; return true }
            // 3. Quiet → keep only if it looks like voice, at a floor low enough for soft speech.
            let voiced = setup.map { voiceBandRatio(frame, setup: $0) >= voiceBandRatioThreshold } ?? true
            let floor = open ? keepFloor : voiceFloor
            let speech = voiced && rms >= floor
            open = speech
            return speech
        }
    }

    /// Root-mean-square of the frame, via `vDSP_rmsqv` (same measure WhisperKit's EnergyVAD uses).
    static func rms(_ frame: ArraySlice<Float>) -> Float {
        guard !frame.isEmpty else { return 0 }
        var result: Float = 0
        let contiguous = Array(frame)
        vDSP_rmsqv(contiguous, 1, &result, vDSP_Length(contiguous.count))
        return result
    }

    /// Fraction of spectral energy that sits in the human voice band vs the full analysis band.
    /// A voiced vowel concentrates energy in ~250–3800 Hz (ratio → ~1); 60 Hz hum / low rumble sit
    /// below the band (ratio → ~0). Uses a Hann-windowed, zero-padded `vDSP` real FFT; the overall
    /// scale cancels in the ratio, so no normalization is needed.
    private func voiceBandRatio(_ frame: ArraySlice<Float>, setup: FFTSetup) -> Float {
        let n = fftSize
        let halfN = n / 2
        guard halfN > 1 else { return 0 }

        // Hann-windowed, zero-padded real signal of length n.
        var signal = [Float](repeating: 0, count: n)
        let base = frame.startIndex
        let m = min(frame.count, n)
        if m > 1 {
            let denom = Float(m - 1)
            for i in 0..<m {
                let w = 0.5 * (1 - cos(2 * Float.pi * Float(i) / denom))
                signal[i] = frame[base + i] * w
            }
        } else if m == 1 {
            signal[0] = frame[base]
        }

        var realp = [Float](repeating: 0, count: halfN)
        var imagp = [Float](repeating: 0, count: halfN)
        var bandEnergy: Float = 0
        var totalEnergy: Float = 0

        realp.withUnsafeMutableBufferPointer { rp in
            imagp.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                signal.withUnsafeBufferPointer { sp in
                    sp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { cp in
                        vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(halfN))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, fftLog2, FFTDirection(kFFTDirection_Forward))
                let binHz = Float(sampleRate) / Float(n)
                // k = 0 is DC (packed with Nyquist in vDSP's zrip layout) — skip it.
                for k in 1..<halfN {
                    let mag2 = rp[k] * rp[k] + ip[k] * ip[k]
                    let f = Float(k) * binHz
                    if f >= analysisLowHz && f <= analysisHighHz { totalEnergy += mag2 }
                    if f >= voiceLowHz && f <= voiceHighHz { bandEnergy += mag2 }
                }
            }
        }
        guard totalEnergy > 0 else { return 0 }
        return bandEnergy / totalEnergy
    }
}
