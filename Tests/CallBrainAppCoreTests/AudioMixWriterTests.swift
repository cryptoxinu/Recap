import Testing
import Foundation
import AVFoundation
import CallBrainAppCore
import CallBrainCore

/// Drives a synthetic two-band tone timeline through the REAL `AudioMixWriter` (relocated from the
/// executable target) and reads the result back through the prod `AudioDecoder`. Proves dual-source
/// capture → mix → sidecar unattended, with no hardware and no ML: the mixed WAV carries BOTH bands
/// at the right windows; the system-only sidecar carries the system band alone; the timeline does
/// not collapse; and no write failed.
@Suite("AudioMixWriter — synthetic dual-source capture → mix → sidecar")
struct AudioMixWriterTests {

    private static let sr = SyntheticAudio.sampleRate

    private static func target() -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sr, channels: 1, interleaved: true)!
    }

    /// A fresh temp dir for one test's WAV + sidecar; the caller removes it in a `defer`.
    private static func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cb-mixwriter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("mixed WAV carries both bands at the right windows; sidecar is system-only; duration ≈ fed length")
    func dualSourceMixAndSidecar() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mixURL = dir.appendingPathComponent("mix.wav")
        let sidecarURL = dir.appendingPathComponent(".mix.system.wav")

        let writer = AudioMixWriter(
            mixURL: mixURL,
            systemSidecarURL: sidecarURL,
            target: Self.target(),
            micSourceRate: Self.sr,
            gateEnabled: false,          // the low-level ingest bypasses the gate anyway
            onLevel: { _ in }
        )
        try #require(writer != nil)
        let w = writer!
        #expect(w.systemURL == sidecarURL)

        drive(SineFrameSource(), into: w)
        _ = w.close()

        #expect(w.writeFailed == false)

        // --- MIX: both bands present, each in its own window ---
        let mix = try await AudioDecoder.decode16kMono(url: mixURL)
        #expect(mix.count > 0)
        // 300 Hz (system) dominates during the two system windows.
        #expect(Goertzel.bandDominates(mix, target: 300, over: 900, sampleRate: Self.sr, in: 0.2..<0.8))
        #expect(Goertzel.bandDominates(mix, target: 300, over: 900, sampleRate: Self.sr, in: 2.2..<2.8))
        // 900 Hz (mic) dominates during the two mic windows.
        #expect(Goertzel.bandDominates(mix, target: 900, over: 300, sampleRate: Self.sr, in: 1.2..<1.8))
        #expect(Goertzel.bandDominates(mix, target: 900, over: 300, sampleRate: Self.sr, in: 3.2..<3.8))

        // Duration ≈ fed length (4.5 s); no timeline collapse or doubling.
        let dur = AudioDecoder.duration(samples: mix.count)
        #expect(dur >= 4.0 && dur <= 4.6)

        // --- SIDECAR: system band only (300 Hz present; 900 Hz at the floor during mic windows) ---
        let sidecar = try await AudioDecoder.decode16kMono(url: sidecarURL)
        #expect(sidecar.count > 0)
        let sys300 = Goertzel.magnitude(sidecar, freq: 300, sampleRate: Self.sr, in: 0.2..<0.8)
        let sys300b = Goertzel.magnitude(sidecar, freq: 300, sampleRate: Self.sr, in: 2.2..<2.8)
        let sys900inMicWindow = Goertzel.magnitude(sidecar, freq: 900, sampleRate: Self.sr, in: 1.2..<1.8)
        let sys900inMicWindowB = Goertzel.magnitude(sidecar, freq: 900, sampleRate: Self.sr, in: 3.2..<3.8)
        #expect(sys300 > 0)
        // The sidecar's system tone dwarfs any energy where only the mic spoke → mic never leaked in.
        #expect(sys300 > sys900inMicWindow * 10)
        #expect(sys300b > sys900inMicWindowB * 10)
    }
}
