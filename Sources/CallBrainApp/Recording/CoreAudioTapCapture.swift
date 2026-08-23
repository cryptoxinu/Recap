import Foundation
@preconcurrency import AVFoundation
import CoreAudio
import CallBrainAppCore

/// Feeds a single conversion pass without re-delivering the same input buffer.
private final class ConvertOnceTap: @unchecked Sendable { var fed = false }

/// `SystemAudioBackend` implemented on the Core Audio process tap. Owns the tap lifecycle, downsamples
/// its f32 frames to the recorder's Int16 16 kHz mono contract OFF the real-time thread, and publishes
/// the SAME `SystemAudioCaptureState` values as the ScreenCaptureKit backend — so `SystemAudioHealth`,
/// the badge, and the 8-second watchdog all keep working unchanged.
///
/// Same init shape as `SystemAudioCapture` (`target` / `onState` / `onSamples`) so the factory can
/// build either behind the `SystemAudioBackend` protocol. `@unchecked Sendable`, NEVER `@MainActor`:
/// all mutable state (`tap`, `converter`, `inputFormat`, `reportedSamples`) is touched only on the
/// private `downsampleQueue`, so no lock is needed and the UI thread is never blocked by capture work.
@available(macOS 14.4, *)
final class CoreAudioTapCapture: SystemAudioBackend, @unchecked Sendable {

    private let target: AVAudioFormat
    private let onSamples: @Sendable ([Int16], UInt64) -> Void
    private let onState: @Sendable (SystemAudioCaptureState) -> Void

    private let downsampleQueue = DispatchQueue(label: "callbrain.coreaudio.tap.downsample")
    // Touched only on downsampleQueue.
    private var tap: CoreAudioProcessTap?
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var reportedSamples = false

    init(target: AVAudioFormat,
         onState: @escaping @Sendable (SystemAudioCaptureState) -> Void,
         onSamples: @escaping @Sendable ([Int16], UInt64) -> Void) {
        self.target = target
        self.onState = onState
        self.onSamples = onSamples
    }

    // MARK: - SystemAudioBackend

    @discardableResult
    func startBestEffort() async -> SystemAudioCaptureState {
        publish(.starting)
        return await withCheckedContinuation { cont in
            downsampleQueue.async { [weak self] in
                guard let self else { cont.resume(returning: .off); return }
                let tap = CoreAudioProcessTap(
                    onRawFrames: { [weak self] floats, nanos in
                        // Fires on the tap's RT ioQueue — hop straight to the downsample queue.
                        guard let self else { return }
                        self.downsampleQueue.async { [weak self] in self?.process(floats, nanos) }
                    },
                    onFormatChange: { [weak self] asbd in
                        // A mid-capture stream-format change — rebuild the converter on our queue.
                        guard let self else { return }
                        self.downsampleQueue.async { [weak self] in self?.adoptFormat(asbd) }
                    })
                self.tap = tap
                do {
                    let asbd = try tap.start()
                    self.adoptFormat(asbd)
                    self.reportedSamples = false
                    self.publish(.capturing)
                    cont.resume(returning: .capturing)
                } catch {
                    tap.stop()   // idempotent — clean any partial setup.
                    self.tap = nil
                    let state = SystemAudioCaptureState.failed(Self.friendly(error))
                    self.publish(state)
                    cont.resume(returning: state)
                }
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { cont in
            downsampleQueue.async { [weak self] in
                self?.tap?.stop()
                self?.tap = nil
                self?.converter = nil
                self?.inputFormat = nil
                cont.resume()
            }
        }
        publish(.off)
    }

    // MARK: - Downsample pipeline (downsampleQueue only)

    private func adoptFormat(_ asbd: AudioStreamBasicDescription) {
        var desc = asbd
        guard let inFormat = AVAudioFormat(streamDescription: &desc) else { return }
        inputFormat = inFormat
        converter = AVAudioConverter(from: inFormat, to: target)
    }

    private func process(_ floats: [Float], _ nanos: UInt64) {
        guard !floats.isEmpty, let inFormat = inputFormat else { return }
        let n = AVAudioFrameCount(floats.count)
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: n),
              let dst = inBuf.floatChannelData else { return }
        inBuf.frameLength = n
        floats.withUnsafeBufferPointer { src in
            if let base = src.baseAddress { dst[0].update(from: base, count: floats.count) }
        }
        guard let out = convert(inBuf), out.frameLength > 0, let ch = out.int16ChannelData else { return }
        let samples = Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
        markReceivedSamples()
        onSamples(samples, nanos)
    }

    private func convert(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if converter == nil || converter?.inputFormat != input.format {
            converter = AVAudioConverter(from: input.format, to: target)
        }
        guard let converter else { return nil }
        let ratio = target.sampleRate / input.format.sampleRate
        let cap = AVAudioFrameCount(Double(input.frameLength) * ratio + 1024)
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return nil }
        let once = ConvertOnceTap()
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if once.fed { status.pointee = .noDataNow; return nil }
            once.fed = true; status.pointee = .haveData; return input
        }
        return err == nil ? out : nil
    }

    private func markReceivedSamples() {
        guard !reportedSamples else { return }
        reportedSamples = true
        publish(.receiving)
    }

    // MARK: - Helpers

    private func publish(_ state: SystemAudioCaptureState) { onState(state) }

    private static func friendly(_ error: Error) -> String {
        // Non-leaky, wellness-neutral: the recorder wraps this as "System audio was not captured
        // (<reason>) - only your mic was recorded." Keep it short and free of raw OSStatus/PHI.
        "the audio tap couldn't start"
    }
}
