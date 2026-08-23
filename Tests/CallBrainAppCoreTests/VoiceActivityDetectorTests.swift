import Testing
import Foundation
import CallBrainAppCore

/// W1c acceptance gate: the spectral VAD KEEPS the founder's quiet speech the shipped 0.008 RMS
/// energy gate DROPPED ("misses some of the things I say"), while STILL gating true silence and low
/// hum — synchronously, per 0.1 s frame, so word onsets are never clipped.
@Suite("SpectralVADGate — keeps quiet speech, still gates silence/hum")
struct VoiceActivityDetectorTests {

    private static let sr: Double = 16_000

    // MARK: - The acceptance gate: quiet speech the old gate drops, the new one keeps

    @Test("quiet voiced burst (RMS ≈ 0.005, below 0.008): OLD EnergyVADGate drops it, NEW SpectralVADGate keeps it")
    func quietVoicedBurstKeptOnlyByNewDetector() {
        // 0.5 s of voiced formant energy at RMS 0.005 — below the shipped 0.008 energy floor.
        let waveform = floatVoicedBurst(rms: 0.005, sampleRate: Self.sr, count: 8_000)

        // Documents the BUG: the crude energy gate sees only sub-0.008 RMS → every frame false.
        let oldMask = EnergyVADGate().voiceActivity(in: waveform)
        #expect(!oldMask.isEmpty)
        #expect(oldMask.allSatisfy { $0 == false })

        // The FIX: the spectral gate recognizes band-limited voice energy and keeps it.
        let newMask = SpectralVADGate().voiceActivity(in: waveform)
        #expect(newMask.contains(true))
    }

    @Test("quiet voiced bursts across the whole 0.004–0.007 dropped band are all kept")
    func quietBandSweepKept() {
        // The load-bearing direction: never drop the founder's quiet speech at ANY level below the
        // old 0.008 floor. (The paired "old gate drops it" is asserted at the safe 0.005 level above;
        // near 0.007 the per-frame RMS of a formant sum can graze 0.008, so we don't over-constrain
        // the old gate here.)
        for milliRMS in 4...7 {
            let rms = Double(milliRMS) / 1_000.0
            let waveform = floatVoicedBurst(rms: rms, sampleRate: Self.sr, count: 8_000)
            #expect(SpectralVADGate().voiceActivity(in: waveform).contains(true),
                    "new gate should keep quiet voiced RMS \(rms)")
        }
    }

    // MARK: - Still gates non-speech

    @Test("true silence reads as no speech (every frame false)")
    func silenceRejected() {
        let silence = [Float](repeating: 0, count: 16_000)
        let mask = SpectralVADGate().voiceActivity(in: silence)
        #expect(!mask.isEmpty)
        #expect(mask.allSatisfy { $0 == false })
    }

    @Test("a low steady hum (60 Hz, RMS ≈ 0.005) is rejected — out of the voice band")
    func lowHumRejected() {
        // 60 Hz mains hum, energy above the noise floor but below 0.008 → the spectral voicing check
        // must reject it (all energy well below the ~250 Hz voice-band floor).
        let hum = floatSine(freq: 60, rms: 0.005, sampleRate: Self.sr, count: 16_000)
        let mask = SpectralVADGate().voiceActivity(in: hum)
        #expect(!mask.contains(true))
    }

    @Test("a quiet out-of-band rumble (120 Hz, RMS ≈ 0.006) is rejected")
    func lowRumbleRejected() {
        let rumble = floatSine(freq: 120, rms: 0.006, sampleRate: Self.sr, count: 16_000)
        #expect(!SpectralVADGate().voiceActivity(in: rumble).contains(true))
    }

    // MARK: - Never regress: strict superset of the shipped 0.008 gate

    @Test("loud speech is still detected (record-when-unsure: loud always passes)")
    func loudSpeechDetected() {
        let loud = floatSine(freq: 900, rms: 0.2, sampleRate: Self.sr, count: 8_000)
        #expect(SpectralVADGate().voiceActivity(in: loud).contains(true))
    }

    @Test("anything the old 0.008 gate keeps, the new gate also keeps (monotonic superset)")
    func newDetectorIsSupersetOfOld() {
        // A tone just above the old floor — the old gate fires; the new one must not regress it.
        let aboveFloor = floatSine(freq: 900, rms: 0.010, sampleRate: Self.sr, count: 8_000)
        #expect(EnergyVADGate().voiceActivity(in: aboveFloor).contains(true))
        #expect(SpectralVADGate().voiceActivity(in: aboveFloor).contains(true))
    }

    @Test("empty input yields an empty mask (no crash, reads as no speech)")
    func emptyInput() {
        #expect(SpectralVADGate().voiceActivity(in: []).isEmpty)
    }
}
