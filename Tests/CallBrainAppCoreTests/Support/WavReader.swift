import Foundation
import AVFoundation

/// Read a 16 kHz mono Int16 WAV back as its EXACT stored Int16 samples (no float normalization),
/// so a test can assert bit-exact mixer output. Uses AVAudioFile with an Int16 reading format that
/// matches the file, so no conversion/resample happens.
enum WavReader {
    static func readInt16Mono(url: URL) throws -> [Int16] {
        // Force the file's processingFormat to Int16 (the default is deinterleaved Float32, which
        // would make `read(into:)` a lossy conversion). With the format matching the stored PCM the
        // read is bit-exact.
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
        guard file.length > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                         frameCapacity: AVAudioFrameCount(file.length)) else {
            return []
        }
        try file.read(into: buf)
        guard let ch = buf.int16ChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(buf.frameLength)))
    }
}

/// A sum of sine tones at `amplitude` (per tone), sampled at ABSOLUTE index so phase is continuous
/// across chunk boundaries (mirrors `int16Sine`'s absolute-index convention). Float output for the
/// `ingestMic` path.
func floatToneMix(freqs: [Double], amplitude: Double, sampleRate: Double,
                  absoluteStart: Int, count: Int) -> [Float] {
    (0..<count).map { i in
        let n = Double(absoluteStart + i)
        let v = freqs.reduce(0.0) { $0 + amplitude * sin(2.0 * Double.pi * $1 * n / sampleRate) }
        return Float(v)
    }
}
