import Foundation

/// One chunk of already-at-target (16 kHz mono Int16) audio with the capture timestamp of its
/// first sample on the shared mach clock (nanoseconds), plus which side of the call it belongs to.
/// The value type the pull-driven capture seam moves across the writer boundary.
public struct AudioFrames: Sendable {
    public let samples: [Int16]
    public let hostTimeNanos: UInt64
    public let isMic: Bool

    public init(samples: [Int16], hostTimeNanos: UInt64, isMic: Bool) {
        self.samples = samples
        self.hostTimeNanos = hostTimeNanos
        self.isMic = isMic
    }
}

/// A pull source of `AudioFrames`. Real capture backends PUSH into the writer via
/// `ingestMic`/`ingestSystem`; `FrameSource` exists so a synthetic (tone) source can PULL-drive
/// the SAME real `AudioMixWriter` deterministically, with no hardware, for the self-test.
public protocol FrameSource: Sendable {
    /// The next chunk, or nil when the source is exhausted.
    func next() -> AudioFrames?
}

/// Pull-drive `source` into `writer` through the low-level `ingestMixSamples` primitive — the SAME
/// mix/place/flush/sidecar path the real backends feed. Runs on the caller's thread; the writer
/// hands the work to its own serial queue.
public func drive(_ source: FrameSource, into writer: AudioMixWriter) {
    while let frame = source.next() {
        writer.ingestMixSamples(frame.samples, atNanos: frame.hostTimeNanos, isMic: frame.isMic)
    }
}
