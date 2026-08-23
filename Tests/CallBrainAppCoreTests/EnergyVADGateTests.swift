import Testing
import Foundation
import CallBrainAppCore

/// The pure energy VAD extracted from the record path (WhisperKit-free). Proves it keeps QUIET
/// speech (the founder's complaint that the 0.008 gate cut soft words) while still reading true
/// silence as no-speech.
@Suite("EnergyVADGate — quiet speech kept, silence rejected")
struct EnergyVADGateTests {

    private static let sr: Double = 16_000

    @Test("a quiet 900 Hz block at RMS ≈ 0.010 (just above 0.008) is detected as speech")
    func quietToneIsSpeech() {
        // 0.5 s of a quiet tone. RMS 0.010 > 0.008 → at least one 0.1 s frame must fire.
        let waveform = floatSine(freq: 900, rms: 0.010, sampleRate: Self.sr, count: 8_000)
        let mask = EnergyVADGate().voiceActivity(in: waveform)
        #expect(mask.contains(true))
    }

    @Test("true silence reads as no speech (every frame false)")
    func silenceIsNotSpeech() {
        let silence = [Float](repeating: 0, count: 16_000)
        let mask = EnergyVADGate().voiceActivity(in: silence)
        #expect(!mask.isEmpty)
        #expect(mask.allSatisfy { $0 == false })
    }

    @Test("a sub-threshold tone (RMS ≈ 0.004) reads as no speech — the floor still holds")
    func belowThresholdIsNotSpeech() {
        let waveform = floatSine(freq: 900, rms: 0.004, sampleRate: Self.sr, count: 8_000)
        let mask = EnergyVADGate().voiceActivity(in: waveform)
        #expect(mask.allSatisfy { $0 == false })
    }

    @Test("empty input yields an empty mask (no crash, reads as no speech)")
    func emptyInput() {
        #expect(EnergyVADGate().voiceActivity(in: []).isEmpty)
    }
}
