import Foundation

/// A gentle soft-knee limiter used at flush, in place of a hard `Int16(clamping:)`, so that loud
/// both-parties passages (two people talking at once) round off the very top instead of hard-
/// clipping into audible distortion.
///
/// It is a strict improvement, transparent for normal audio:
///   • For |x| ≤ `knee` (28000, ≈85% of full scale) the output is EXACTLY `Int16(x)` — bit-identical
///     to the old hard clamp, since 28000 is well inside Int16 range. So quiet/normal recordings
///     (and the W2 tone self-tests, whose mixed peak is ≈9830) are unchanged.
///   • For |x| > `knee` the region [knee, ∞) is smoothly compressed into [knee, ceiling) with a tanh
///     curve whose slope is 1 at the knee (C¹-continuous — no corner) and which asymptotes to the
///     ceiling without ever reaching it, so the result is always a valid Int16 and never wraps.
///
/// Only samples that are already near/over full scale are reshaped; anything a normal recording
/// produces passes through untouched.
public enum MixSoftLimiter {
    /// Below this magnitude the limiter is an exact pass-through (== hard clamp). Tunable in one place.
    public static let knee: Int32 = 28_000
    /// The Int16 ceiling the curve asymptotes toward (never reached).
    public static let ceiling: Float = 32_767

    @inline(__always)
    public static func limit(_ x: Int32) -> Int16 {
        let mag = x.magnitude                              // UInt32
        if mag <= UInt32(knee) { return Int16(x) }         // exact pass-through (in Int16 range)
        let headroom = ceiling - Float(knee)               // 4767
        let over = Float(mag) - Float(knee)
        let compressed = Float(knee) + headroom * tanhf(over / headroom)  // < ceiling, strictly
        let signed = x < 0 ? -compressed : compressed
        return Int16(signed.rounded())
    }
}
