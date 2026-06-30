import Foundation
import AVFoundation

public enum AudioDecodeError: Error, Sendable, Equatable {
    case noAudioTrack
    case readFailed(String)
    case tooLong(hours: Double)
}

/// Decodes any AVFoundation-readable file (`.mp4`/`.mov`/`.m4a`/`.wav`/…) into **16 kHz mono Float32**
/// samples — the input format Whisper expects (Phase 3). Pure AVFoundation, no ML model, fully on-device.
/// `AVAssetReaderTrackOutput` decompresses + resamples to the requested format in one pass.
public enum AudioDecoder {
    public static let targetSampleRate = 16_000
    /// Reject absurdly long recordings before materializing the whole sample buffer in memory
    /// (a 16 kHz mono hour ≈ 230 MB of Float). 6 h covers any real meeting; beyond that we refuse
    /// rather than risk OOM (Codex P3 gate HIGH).
    public static let maxDurationSeconds = 6 * 3600

    public static func decode16kMono(url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw AudioDecodeError.noAudioTrack
        }
        // Bound by the asset's reported duration before reading.
        if let seconds = try? await asset.load(.duration).seconds, seconds.isFinite, seconds > 0 {
            if Int(seconds) > maxDurationSeconds {
                throw AudioDecodeError.tooLong(hours: (seconds / 3600).rounded(.up))
            }
        }
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: targetSampleRate,
            AVNumberOfChannelsKey: 1,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw AudioDecodeError.readFailed("cannot add output") }
        reader.add(output)
        guard reader.startReading() else {
            throw AudioDecodeError.readFailed(reader.error?.localizedDescription ?? "startReading failed")
        }

        var samples: [Float] = []
        // Reserve up to the duration estimate so the array doesn't repeatedly double (≤ the cap above).
        if let seconds = try? await asset.load(.duration).seconds, seconds.isFinite, seconds > 0 {
            samples.reserveCapacity(min(Int(seconds) * targetSampleRate, maxDurationSeconds * targetSampleRate))
        }
        while let buffer = output.copyNextSampleBuffer() {
            if let block = CMSampleBufferGetDataBuffer(buffer) {
                let length = CMBlockBufferGetDataLength(block)
                let count = length / MemoryLayout<Float>.size
                if count > 0 {
                    var chunk = [Float](repeating: 0, count: count)
                    chunk.withUnsafeMutableBytes { raw in
                        _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length,
                                                       destination: raw.baseAddress!)
                    }
                    samples.append(contentsOf: chunk)
                }
            }
            CMSampleBufferInvalidate(buffer)
        }
        if reader.status == .failed {
            throw AudioDecodeError.readFailed(reader.error?.localizedDescription ?? "read failed")
        }
        return samples
    }

    /// Duration in seconds implied by a 16 kHz mono sample buffer.
    public static func duration(samples: Int) -> Double { Double(samples) / Double(targetSampleRate) }
}
