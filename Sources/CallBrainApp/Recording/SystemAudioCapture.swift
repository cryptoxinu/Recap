import Foundation
@preconcurrency import AVFoundation
import ScreenCaptureKit
import CallBrainAppCore

private final class ConvertOnceSys: @unchecked Sendable { var fed = false }

/// Captures the Mac's SYSTEM audio (what you hear — the other participants on a headset call)
/// via ScreenCaptureKit and delivers it converted to the recorder's target format. Best-effort,
/// but not silent: setup failures and no-sample sessions are surfaced to the recorder UI.
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {

    private let target: AVAudioFormat
    /// Delivers resampled system audio (Int16 16k mono, Sendable) + a monotonic capture timestamp
    /// so the writer can align it on the mic's timeline. No non-Sendable buffer crosses a boundary.
    private let onSamples: @Sendable ([Int16], UInt64) -> Void
    private let onState: @Sendable (SystemAudioCaptureState) -> Void
    private var stream: SCStream?
    private var converter: AVAudioConverter?
    private let sampleQueue = DispatchQueue(label: "callbrain.systemaudio")
    private let stateLock = NSLock()
    private var reportedSamples = false
    private static let screenAudioSampleRate = 48_000
    private static let screenAudioChannelCount = 2

    init(target: AVAudioFormat,
         onState: @escaping @Sendable (SystemAudioCaptureState) -> Void,
         onSamples: @escaping @Sendable ([Int16], UInt64) -> Void) {
        self.target = target
        self.onState = onState
        self.onSamples = onSamples
    }

    /// Try to start system-audio capture. Never throws; failure means mic-only plus a visible warning.
    @discardableResult
    func startBestEffort() async -> SystemAudioCaptureState {
        publish(.starting)
        do {
            // Any display works — we only take audio, no frames. excludingWindows keeps it cheap.
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let display = content.displays.first else {
                let state = SystemAudioCaptureState.failed("No capturable display was available.")
                publish(state)
                return state
            }
            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true    // don't record our own sounds
            // Ask ScreenCaptureKit for native call-audio shape, then downsample/downmix locally
            // to the recorder's 16 kHz mono WAV. Requesting the final 16 kHz mono format here
            // has proven brittle with live meeting audio.
            config.sampleRate = Self.screenAudioSampleRate
            config.channelCount = Self.screenAudioChannelCount
            // Minimal video (SCStream requires a display) — tiny + slow so it's ~free.
            config.width = 2; config.height = 2; config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

            let s = SCStream(filter: filter, configuration: config, delegate: self)
            try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
            try await s.startCapture()
            stream = s
            publish(.capturing)
            return .capturing
        } catch {
            stream = nil   // mic-only fallback
            let state = SystemAudioCaptureState.failed(Self.friendly(error))
            publish(state)
            return state
        }
    }

    func stop() async {
        guard let s = stream else { return }
        try? await s.stopCapture()
        stream = nil
        publish(.off)
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid,
              let pcm = Self.pcmBuffer(from: sampleBuffer),
              let converted = convert(pcm), converted.frameLength > 0,
              let ch = converted.int16ChannelData else { return }
        // The sample's own capture time on the mach host clock (SCStream PTS rides it), converted
        // to ns so it shares the mic tap's timeline — not the callback's arrival time (P2b HIGH).
        let pts = sampleBuffer.presentationTimeStamp
        let t: UInt64
        if pts.isValid {
            let ns = CMTimeConvertScale(pts, timescale: 1_000_000_000, method: .roundHalfAwayFromZero)
            t = ns.value > 0 ? UInt64(ns.value) : DispatchTime.now().uptimeNanoseconds
        } else {
            t = DispatchTime.now().uptimeNanoseconds
        }
        let samples = Array(UnsafeBufferPointer(start: ch[0], count: Int(converted.frameLength)))
        markReceivedSamples()
        onSamples(samples, t)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        publish(.failed(Self.friendly(error)))
    }

    /// CMSampleBuffer (system audio, typically 48 kHz float) → AVAudioPCMBuffer in its native
    /// format, then converted to the recorder's Int16 16 kHz mono.
    private static func pcmBuffer(from sample: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let fmtDesc = sample.formatDescription,
              let asbd = fmtDesc.audioStreamBasicDescription else { return nil }
        var streamDesc = asbd
        guard let format = AVAudioFormat(streamDescription: &streamDesc) else { return nil }
        let frames = AVAudioFrameCount(sample.numSamples)
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buf.frameLength = frames
        let abl = buf.mutableAudioBufferList
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sample, at: 0, frameCount: Int32(frames), into: abl)
        return status == noErr ? buf : nil
    }

    private func convert(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if converter == nil || converter?.inputFormat != input.format {
            converter = AVAudioConverter(from: input.format, to: target)
        }
        guard let converter else { return nil }
        let ratio = target.sampleRate / input.format.sampleRate
        let cap = AVAudioFrameCount(Double(input.frameLength) * ratio + 1024)
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return nil }
        let once = ConvertOnceSys(); var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if once.fed { status.pointee = .noDataNow; return nil }
            once.fed = true; status.pointee = .haveData; return input
        }
        return err == nil ? out : nil
    }

    private func markReceivedSamples() {
        let shouldPublish = stateLock.withLock {
            if reportedSamples { return false }
            reportedSamples = true
            return true
        }
        if shouldPublish { publish(.receiving) }
    }

    private func publish(_ state: SystemAudioCaptureState) {
        onState(state)
    }

    private static func friendly(_ error: Error) -> String {
        let message = (error as NSError).localizedDescription
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if message.isEmpty {
            return "Screen audio capture failed."
        }
        if message.localizedCaseInsensitiveContains("permission") ||
            message.localizedCaseInsensitiveContains("privacy") {
            return "Screen Recording permission is off."
        }
        return message
    }
}
