import Testing
import Foundation
import AVFoundation
import CallBrainAppCore
import CallBrainCore

/// W1e — recording mix-quality chain. Proves, unattended and with no hardware:
///   1. the mic ~80 Hz high-pass attenuates a 40 Hz mic component while leaving the 900 Hz mic tone
///      intact, and never touches the 300 Hz system band;
///   2. mic-dominant ducking is OFF by default (mixed output = straight Int16 sum, byte-identical to
///      pre-W1e), and when ON lowers the system in the MAIN mix while the diarization sidecar stays
///      FULL level;
///   3. the flush soft-limiter is a no-op for in-range samples and only bends near full-scale.
@Suite("MixQualityChain — W1e mic HPF + ducking + soft-limiter")
struct MixQualityChainTests {

    private static let sr = SyntheticAudio.sampleRate
    private static let nsPerSample = SyntheticAudio.nsPerSample

    private static func target() -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sr, channels: 1, interleaved: true)!
    }

    private static func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cb-mixquality-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - 1. Mic high-pass

    @Test("mic HPF attenuates 40 Hz, keeps 900 Hz; system 300 Hz unaffected")
    func micHighPassRemovesLowFrequency() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mixURL = dir.appendingPathComponent("mix.wav")
        let sidecarURL = dir.appendingPathComponent(".mix.system.wav")

        // micSourceRate == target rate so `ingestMic` floats are the 16 kHz mic band with no resample.
        let writer = AudioMixWriter(mixURL: mixURL, systemSidecarURL: sidecarURL, target: Self.target(),
                                    micSourceRate: Self.sr, gateEnabled: false, onLevel: { _ in })
        try #require(writer != nil)
        let w = writer!

        let epoch: UInt64 = 2_000_000_000
        let sr = Self.sr
        // System 300 Hz over [0,1)s via the Int16 path (never high-passed).
        var frame = 0
        while frame < 16_000 {
            let count = min(SyntheticAudio.chunk, 16_000 - frame)
            let s = int16Sine(freq: 300, amplitude: SyntheticAudio.loudAmplitude,
                              sampleRate: sr, absoluteStart: frame, count: count)
            w.ingestSystem(s, atNanos: epoch + UInt64(frame) * Self.nsPerSample)
            frame += count
        }
        // Mic 40 Hz + 900 Hz over [1,2)s via the float path (the ONLY path the HPF sees), fed in small
        // chunks so filter-state carrying across buffers is exercised (a per-buffer reset would leak
        // extra low-frequency transients and inflate the 40 Hz reading).
        frame = 16_000
        while frame < 32_000 {
            let count = min(SyntheticAudio.chunk, 32_000 - frame)
            let f = floatToneMix(freqs: [40, 900], amplitude: 0.3, sampleRate: sr,
                                 absoluteStart: frame, count: count)
            w.ingestMic(f, atNanos: epoch + UInt64(frame) * Self.nsPerSample)
            frame += count
        }
        _ = w.close()
        #expect(w.writeFailed == false)

        let mix = try await AudioDecoder.decode16kMono(url: mixURL)
        #expect(mix.count > 0)

        // Mic window [1.25,1.75): 40 Hz equal-amplitude input, so the 900/40 magnitude ratio IS the
        // filter's relative response. Butterworth 2nd-order at 80 Hz → 40 Hz ≈ 0.24, 900 Hz ≈ 1.0.
        let mag40 = Goertzel.magnitude(mix, freq: 40, sampleRate: sr, in: 1.25..<1.75)
        let mag900 = Goertzel.magnitude(mix, freq: 900, sampleRate: sr, in: 1.25..<1.75)
        #expect(mag900 > 0)
        #expect(mag900 > mag40 * 2.5)                 // 40 Hz clearly attenuated relative to 900 Hz

        // System window [0.2,0.8): 300 Hz present and NOT attenuated (never high-passed).
        let mag300 = Goertzel.magnitude(mix, freq: 300, sampleRate: sr, in: 0.2..<0.8)
        #expect(mag300 > 0)
        // 900 Hz mic tone passes essentially unattenuated → comparable to the equal-amplitude 300 Hz
        // system tone, proving the passband is intact (not just that 40 Hz is small).
        #expect(mag900 > mag300 * 0.5)

        // Sidecar carries the system 300 Hz (unaffected by the mic HPF).
        let sidecar = try await AudioDecoder.decode16kMono(url: sidecarURL)
        #expect(Goertzel.magnitude(sidecar, freq: 300, sampleRate: sr, in: 0.2..<0.8) > 0)
    }

    // MARK: - 2. Ducking (default OFF = straight sum; ON ducks main mix only)

    /// Feed constant, frame-aligned mic + system streams (via the low-level Int16 path, so no HPF /
    /// gate / resampler) and return the mixed + sidecar Int16 samples.
    private static func feedConstant(dir: URL, micVal: Int16, sysVal: Int16,
                                     frames: Int, micDominant: Bool) throws -> (mix: [Int16], sidecar: [Int16]) {
        let stem = "mix-\(UUID().uuidString)"
        let mixURL = dir.appendingPathComponent("\(stem).wav")
        let sidecarURL = dir.appendingPathComponent(".\(stem).system.wav")
        let writer = AudioMixWriter(mixURL: mixURL, systemSidecarURL: sidecarURL, target: target(),
                                    micSourceRate: sr, gateEnabled: false, micDominantMix: micDominant,
                                    onLevel: { _ in })
        try #require(writer != nil)
        let w = writer!
        let epoch: UInt64 = 3_000_000_000
        var frame = 0
        while frame < frames {
            let count = min(SyntheticAudio.chunk, frames - frame)
            let stamp = epoch + UInt64(frame) * nsPerSample
            w.ingestMixSamples([Int16](repeating: micVal, count: count), atNanos: stamp, isMic: true)
            w.ingestMixSamples([Int16](repeating: sysVal, count: count), atNanos: stamp, isMic: false)
            frame += count
        }
        _ = w.close()
        #expect(w.writeFailed == false)
        return (try WavReader.readInt16Mono(url: mixURL), try WavReader.readInt16Mono(url: sidecarURL))
    }

    @Test("ducking OFF = byte-identical straight sum; ON ducks the main mix only; sidecar stays full-level")
    func duckingDefaultOffElseScalesMainMixOnly() throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let micVal: Int16 = 1_000
        let sysVal: Int16 = 2_000
        let frames = 8_000        // 0.5 s — well inside the 2 s flush window, so one clean file

        let off = try Self.feedConstant(dir: dir, micVal: micVal, sysVal: sysVal, frames: frames, micDominant: false)
        let on  = try Self.feedConstant(dir: dir, micVal: micVal, sysVal: sysVal, frames: frames, micDominant: true)

        #expect(off.mix.count >= frames - SyntheticAudio.chunk)
        #expect(on.mix.count >= frames - SyntheticAudio.chunk)

        // Interior slice (avoid any first/last-chunk boundary) — every sample is a pure mic+system sum.
        let lo = 2_000, hi = 6_000
        let expectedDuck = Int16((Float(sysVal) * AudioMixWriter.systemDuckScale).rounded())  // 1600
        for i in lo..<hi {
            // OFF: byte-identical straight sum (pre-W1e behavior).
            #expect(off.mix[i] == micVal + sysVal)                 // 3000
            // ON: mic full-level + ducked system in the MAIN mix.
            #expect(on.mix[i] == micVal + expectedDuck)            // 2600
            // Sidecar (diarization channel) is FULL-level system in BOTH cases — never ducked.
            #expect(off.sidecar[i] == sysVal)                      // 2000
            #expect(on.sidecar[i] == sysVal)                       // 2000
        }
        // The duck genuinely lowered the system in the main mix.
        #expect(on.mix[lo] < off.mix[lo])
        // Timeline unchanged by ducking: same number of mixed frames.
        #expect(off.mix.count == on.mix.count)
    }

    // MARK: - 3. Soft-limiter

    @Test("soft-limiter: exact pass-through in range, bends (never wraps) near full-scale")
    func softLimiterIsTransparentBelowKneeAndBendsAbove() {
        // No-op for in-range magnitudes (identical to Int16(clamping:)).
        #expect(MixSoftLimiter.limit(0) == 0)
        #expect(MixSoftLimiter.limit(9_000) == 9_000)
        #expect(MixSoftLimiter.limit(-9_000) == -9_000)
        #expect(MixSoftLimiter.limit(MixSoftLimiter.knee) == Int16(MixSoftLimiter.knee))     // exactly at the knee
        #expect(MixSoftLimiter.limit(-MixSoftLimiter.knee) == Int16(-MixSoftLimiter.knee))

        // Above the knee it bends: strictly below the Int16 ceiling (proves it did NOT hard-clip to
        // 32767) yet still near full-scale, and monotonic + sign-symmetric.
        let bent = MixSoftLimiter.limit(40_000)
        #expect(bent < 32_767)                 // would have hard-clamped to 32767 before
        #expect(bent > 31_000)                 // still near the ceiling (gentle knee)
        #expect(MixSoftLimiter.limit(60_000) > bent)                     // monotonic
        #expect(MixSoftLimiter.limit(-40_000) == Int16(-Int(bent)))      // symmetric
        // Extreme input never overflows Int16.
        #expect(MixSoftLimiter.limit(Int32.max) <= 32_767)
        #expect(MixSoftLimiter.limit(Int32.min) >= -32_768)
    }

    @Test("soft-limiter reaches the mixed WAV only for would-clip sums; normal sums are untouched")
    func softLimiterAppliesAtFlushForOverRangeOnly() throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Sum 9000 (in range) → written exactly.
        let normal = try Self.feedConstant(dir: dir, micVal: 4_000, sysVal: 5_000, frames: 8_000, micDominant: false)
        // Sum 40000 (would hard-clip) → soft-limited to the pure-function value.
        let loud = try Self.feedConstant(dir: dir, micVal: 20_000, sysVal: 20_000, frames: 8_000, micDominant: false)

        let expectedLoud = MixSoftLimiter.limit(40_000)
        for i in 2_000..<6_000 {
            #expect(normal.mix[i] == 9_000)          // no-op for normal-level audio
            #expect(loud.mix[i] == expectedLoud)     // gently limited, not hard-clipped
            #expect(loud.mix[i] < 32_767)
        }
    }
}
