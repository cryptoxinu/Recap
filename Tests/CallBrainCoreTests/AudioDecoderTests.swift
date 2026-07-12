import Testing
import Foundation
@testable import CallBrainCore

@Suite("AudioDecoder (AVFoundation → 16kHz mono)")
struct AudioDecoderTests {
    static let realVideo = "/Users/z/Downloads/BasisPromo.mp4"

    @Test("a missing audio track throws, not crashes")
    func noTrack() async throws {
        // A text file masquerading as media → no audio track.
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("cb-noaudio-\(UUID().uuidString).mp4")
        try Data("not a video".utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        await #expect(throws: Error.self) { _ = try await AudioDecoder.decode16kMono(url: tmp) }
    }

    @Test("LIVE: decodes a real .mp4 to non-empty 16kHz mono samples",
          .enabled(if: FileManager.default.fileExists(atPath: AudioDecoderTests.realVideo)))
    func liveDecode() async throws {
        let samples = try await AudioDecoder.decode16kMono(url: URL(fileURLWithPath: Self.realVideo))
        #expect(!samples.isEmpty)
        let dur = AudioDecoder.duration(samples: samples.count)
        #expect(dur > 1)                       // a promo video is at least a few seconds
        // samples are normalized float audio in roughly [-1, 1]
        let peak = samples.map(abs).max() ?? 0
        #expect(peak > 0 && peak <= 1.5)
        print("DECODED \(samples.count) samples = \(String(format: "%.1f", dur))s @16kHz, peak \(String(format: "%.3f", peak))")
    }
}
