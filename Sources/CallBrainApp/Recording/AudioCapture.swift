import Foundation
@preconcurrency import AVFoundation
import CallBrainCore
import CallBrainAppCore
#if canImport(WhisperKit)
import WhisperKit
#endif

/// Single-feed token for the AVAudioConverter pull closure (a class ref instead of a captured
/// mutable var, so the pull closure doesn't warn).
private final class ConvertOnce: @unchecked Sendable { var fed = false }

/// mach host-time ticks → nanoseconds. The mic tap's `AVAudioTime.hostTime` and ScreenCaptureKit's
/// CMSampleBuffer host-clock PTS both ride mach_absolute_time, so converting both to ns puts the
/// two streams on ONE clock — the buffer's CAPTURE time, not the callback's arrival time (P2b HIGH).
private let machTimebase: mach_timebase_info_data_t = {
    var info = mach_timebase_info_data_t(); mach_timebase_info(&info); return info
}()
func hostTicksToNanos(_ ticks: UInt64) -> UInt64 {
    machTimebase.denom == 0 ? ticks
        : UInt64((Double(ticks) * Double(machTimebase.numer)) / Double(machTimebase.denom))
}

/// Owns the output file + a time-aligned MIX of the mic and system-audio streams, and does ALL
/// heavy work on ONE private serial queue — never on the real-time audio threads. The audio
/// callbacks only extract plain sample arrays (Sendable) + a monotonic timestamp and hand them
/// over; conversion, mixing, and file I/O happen on the writer queue. This fixes two P1-audit
/// HIGHs at once: (1) mic + system audio are SUMMED on a shared timeline (not concatenated into
/// an incoherent file), and (2) the audio callback never blocks on disk I/O or a cross-stream
/// lock. Only `[Float]`/`[Int16]`/`UInt64`/`Double` cross a thread boundary, so there is no
/// data race on a non-Sendable AVAudioPCMBuffer.
private final class RecordingWriter: @unchecked Sendable {
    private let q = DispatchQueue(label: "callbrain.rec.writer", qos: .userInitiated)
    private var file: AVAudioFile?
    /// The remote-participants-only (system audio) sibling, written frame-aligned with the mixed WAV so the
    /// post-call pass can diarize a CLEAN remote channel for group attribution (T3). nil when not capturing
    /// system audio, or if the file couldn't be created — either way the pipeline falls back to mono.
    private var systemFile: AVAudioFile?
    private(set) var systemURL: URL?
    private var accSys: [Int32] = []           // system-only accumulator, index-aligned with `acc`
    private let target: AVAudioFormat          // Int16 16k mono
    private let sampleRate: Double
    private let micSourceRate: Double          // engine input rate (set once, before any callback)
    private var micFormat: AVAudioFormat?      // mono float @ micSourceRate — the converter input
    private var micConverter: AVAudioConverter?
    private let onMicSamples: (@Sendable ([Int16], UInt64) -> Void)?
    private let onSystemSamples: (@Sendable ([Int16], UInt64) -> Void)?
    private let onMicState: (@Sendable (MicState) -> Void)?
    private let onLevel: @Sendable (Float) -> Void
    let url: URL

    // Mix accumulator. `acc[i]` holds absolute frame (accBase + i), summed in Int32 so two Int16
    // streams add without mid-mix clipping (clamped to Int16 only on flush). Bounded by a ~1s
    // flush window: anything older than the newest frame minus the window can't still be waiting
    // on a late buffer from the other stream, so it's written and dropped from memory.
    private var acc: [Int32] = []
    private var accBase: Int64 = 0             // absolute frame index of acc[0]
    private var startNanos: UInt64 = 0         // first buffer's capture clock (0 = unset)
    private var lastMicEndFrame: Int64 = 0     // highest absolute frame written by the mic stream
    private(set) var writeFailed = false       // a MIXED-file write threw → the WAV may be truncated
    private var systemWriteFailed = false      // a SYSTEM-sidecar write failed → abandon it (no dual channel)
    private static let flushWindowFrames: Int64 = 32_000   // ~2s @16k — covers inter-stream skew
    private var micGate: MicGate
    private var lastMicState: MicState?
    private let forceMuteLock = NSLock()
    private var forceMutedStorage = false
    #if canImport(WhisperKit)
    // Lower than WhisperKit's default 0.02 so QUIET speech isn't dropped — founder had to talk loudly and
    // the gate still cut words. Err toward capturing; true silence is still well below this.
    private let vad = EnergyVAD(sampleRate: 16_000, energyThreshold: 0.008)
    #endif

    init?(target: AVAudioFormat,
          micSourceRate: Double,
          gateEnabled: Bool = true,
          writeSystemSidecar: Bool = false,
          onMicSamples: (@Sendable ([Int16], UInt64) -> Void)? = nil,
          onSystemSamples: (@Sendable ([Int16], UInt64) -> Void)? = nil,
          onMicState: (@Sendable (MicState) -> Void)? = nil,
          onLevel: @escaping @Sendable (Float) -> Void) {
        self.target = target; self.sampleRate = target.sampleRate
        self.micSourceRate = micSourceRate > 0 ? micSourceRate : target.sampleRate
        // Generous pre-roll + hangover so the gate captures the ONSET of a word and doesn't cut trailing
        // words or brief mid-sentence pauses (founder: "misses some of the things I say").
        self.micGate = MicGate(gateEnabled: gateEnabled, sampleRate: Int(target.sampleRate),
                               preRollSeconds: 0.5, hangoverSeconds: 1.2)
        self.onMicSamples = onMicSamples
        self.onSystemSamples = onSystemSamples
        self.onMicState = onMicState
        self.onLevel = onLevel
        // Write recordings to the SINGLE durable folder (Application Support/CallBrain/Recordings) — never
        // the system temp dir, which macOS purges. `RecordingStorage` owns the location so Settings can
        // show + clear it (data-safety #72).
        let u = RecordingStorage.directory()
            .appendingPathComponent("callbrain-rec-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        // processingFormat MUST match the Int16 buffers we write (`target`), else AVAudioFile defaults
        // its processingFormat to Float32 and `write(from:)` trips a CoreAudio ExtAudioFile assertion
        // (EXC_BREAKPOINT / CAAssertRtn) on the first flush — crash report Recap-2026-07-05-123922.
        guard let f = try? AVAudioFile(forWriting: u, settings: settings,
                                       commonFormat: .pcmFormatInt16, interleaved: true) else { return nil }
        file = f; url = u
        // Open the system-only sibling when we're capturing the other participants (T3). Best-effort: if it
        // can't be created we just skip dual-channel — the mixed WAV (and mono transcription) is unaffected.
        if writeSystemSidecar {
            let sysURL = RecordingSidecars.systemAudioURL(forRecording: u)
            if let sf = try? AVAudioFile(forWriting: sysURL, settings: settings,
                                         commonFormat: .pcmFormatInt16, interleaved: true) {
                systemFile = sf; systemURL = sysURL
            }
        }
    }

    /// Force the mic gate closed from another thread. The flag is lock-guarded; the state machine
    /// itself still advances only on `q`.
    func setForceMuted(_ muted: Bool) {
        forceMuteLock.withLock { forceMutedStorage = muted }
        q.async { [weak self] in self?.applyMicGateControlChange() }
    }

    /// Toggle VAD gating. When disabled, the mic path emits every converted buffer unless the
    /// external force-mute override is active.
    func setGateEnabled(_ enabled: Bool) {
        q.async { [weak self] in
            guard let self else { return }
            micGate = micGate.settingGateEnabled(enabled)
            applyMicGateControlChange()
        }
    }

    // MARK: - ingest (called from audio threads — cheap, non-blocking)

    /// Mic samples, channel 0, at the engine's native rate. Converted + mixed on the queue.
    func ingestMic(_ samples: [Float], atNanos t: UInt64) {
        guard !samples.isEmpty else { return }
        q.async { [weak self] in self?.mixMic(samples, t) }
    }

    /// System audio, already resampled to the target (Int16 16k mono) by SystemAudioCapture.
    func ingestSystem(_ samples: [Int16], atNanos t: UInt64) {
        guard !samples.isEmpty else { return }
        q.async { [weak self] in self?.mix(samples, at: t, isMic: false) }
        onSystemSamples?(samples, t)
    }

    // MARK: - queue-only work

    private func mixMic(_ floats: [Float], _ t: UInt64) {
        guard let converted = convertMic(floats) else { return }
        reportLevel(converted)

        let muted = forceMuted()
        let hasSpeech = muted || !micGate.gateEnabled ? false : containsSpeech(in: converted)
        let outcome = micGate.process(MicGateBuffer(samples: converted, timestampNanos: t),
                                      isSpeech: hasSpeech,
                                      forceMuted: muted)
        micGate = outcome.gate
        publishMicState(outcome.decision.state)

        for buffer in outcome.decision.buffersToEmit {
            mix(buffer.samples, at: buffer.timestampNanos, isMic: true)
            onMicSamples?(buffer.samples, buffer.timestampNanos)
        }

        // Once the gate is closed, discard any resampler lookahead from gated-out mic input so
        // `close()` cannot later drain and place it into the mixed WAV.
        if outcome.decision.state == .silent || outcome.decision.state == .muted {
            micConverter = nil
        }
    }

    /// Rebuild a mono float buffer at the source rate, resample to the target, return Int16.
    private func convertMic(_ floats: [Float]) -> [Int16]? {
        if micFormat == nil {
            micFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: micSourceRate,
                                      channels: 1, interleaved: false)
        }
        guard let micFormat else { return nil }
        if micConverter == nil { micConverter = AVAudioConverter(from: micFormat, to: target) }
        guard let conv = micConverter,
              let inBuf = AVAudioPCMBuffer(pcmFormat: micFormat, frameCapacity: AVAudioFrameCount(floats.count)),
              let src = inBuf.floatChannelData else { return nil }
        inBuf.frameLength = AVAudioFrameCount(floats.count)
        floats.withUnsafeBufferPointer { p in src[0].update(from: p.baseAddress!, count: floats.count) }

        let ratio = target.sampleRate / micSourceRate
        let cap = AVAudioFrameCount(Double(floats.count) * ratio + 1024)
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return nil }
        let once = ConvertOnce(); var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if once.fed { status.pointee = .noDataNow; return nil }
            once.fed = true; status.pointee = .haveData; return inBuf
        }
        guard err == nil else { return nil }
        return samples(from: out)
    }

    private func mix(_ samples: [Int16], at t: UInt64, isMic: Bool) {
        guard !samples.isEmpty else { return }
        if startNanos == 0 { startNanos = t }
        // SIGNED delta (P2b audit HIGH): a buffer whose capture time precedes the epoch — possible
        // when the first buffer PROCESSED isn't the first CAPTURED across the two stream queues —
        // must clamp to 0, never wrap UInt64 into an absurd positive frame index.
        let deltaNs = Int64(bitPattern: t) &- Int64(bitPattern: startNanos)
        let elapsed = deltaNs > 0 ? Int64(Double(deltaNs) / 1_000_000_000.0 * sampleRate) : 0
        place(samples, atFrame: elapsed, isMic: isMic)
        // Flush everything older than the window.
        flush(upTo: accBase + Int64(acc.count) - Self.flushWindowFrames)
    }

    /// Sum `samples` into the accumulator at absolute `frame` (clamped to the current base so a
    /// very late straggler is butted onto the edge rather than dropped). Tracks the mic tail frame
    /// so the resampler drain lands at the right place, not at frame 0.
    private func place(_ samples: [Int16], atFrame frame: Int64, isMic: Bool) {
        guard file != nil else { return }
        let start = max(accBase, frame)
        let localStart = Int(start - accBase)
        let needed = localStart + samples.count
        if acc.count < needed { acc.append(contentsOf: repeatElement(0, count: needed - acc.count)) }
        for i in 0..<samples.count { acc[localStart + i] += Int32(samples[i]) }
        // Keep the system-only accumulator index-aligned with the mixed one and add ONLY system samples to it,
        // so `<stem>.system.wav` is the remote channel alone for clean group diarization (T3).
        if systemFile != nil {
            if accSys.count < needed { accSys.append(contentsOf: repeatElement(0, count: needed - accSys.count)) }
            if !isMic { for i in 0..<samples.count { accSys[localStart + i] += Int32(samples[i]) } }
        }
        if isMic { lastMicEndFrame = max(lastMicEndFrame, start + Int64(samples.count)) }
    }

    private func flush(upTo absFrame: Int64) {
        let count = min(Int(absFrame - accBase), acc.count)
        guard count > 0, let file else { return }
        if !write(Array(acc[0..<count]), to: file) { writeFailed = true }
        if let systemFile {
            // If the system write fails (or the accumulators ever desync), ABANDON the sidecar: drop the
            // file + buffer so we never advance the shared timeline for the mixed WAV while the sidecar
            // falls behind — a truncated/misaligned remote channel would mis-attribute (audit LOW). The
            // recording keeps its mixed WAV and simply falls back to mono transcription.
            if accSys.count >= count, write(Array(accSys[0..<count]), to: systemFile) {
                accSys.removeFirst(count)
            } else {
                systemWriteFailed = true
                self.systemFile = nil
                accSys.removeAll()
            }
        }
        acc.removeFirst(count)
        accBase += Int64(count)
    }

    /// Drain the converter tail + write everything still buffered, then close the file.
    func close() -> URL {
        q.sync {
            // Place the resampler's remaining tail at the mic's ACTUAL last frame, not frame 0
            // (P2b audit MED) — otherwise it overlays the start of the recording.
            if let conv = micConverter, let tail = drainMic(conv) {
                place(tail, atFrame: lastMicEndFrame, isMic: true)
            }
            if let file, !acc.isEmpty, !write(acc, to: file) { writeFailed = true }
            if let systemFile, !accSys.isEmpty, !write(accSys, to: systemFile) { systemWriteFailed = true }
            // A partial/desynced sidecar is worse than none — delete it so transcription uses the mono path.
            if systemWriteFailed, let systemURL { try? FileManager.default.removeItem(at: systemURL) }
            acc.removeAll(); accSys.removeAll(); micConverter = nil; file = nil; systemFile = nil
        }
        return url
    }

    /// Flush the resampler's remaining lookahead frames with `.endOfStream` (P1 audit MED — the
    /// per-buffer `.noDataNow` feed leaves a few tail frames buffered inside the converter).
    private func drainMic(_ conv: AVAudioConverter) -> [Int16]? {
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 4096) else { return nil }
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in status.pointee = .endOfStream; return nil }
        guard err == nil, out.frameLength > 0 else { return nil }
        return samples(from: out)
    }

    // MARK: - low-level

    private func samples(from buffer: AVAudioPCMBuffer) -> [Int16]? {
        guard let ch = buffer.int16ChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: ch, count: Int(buffer.frameLength)))
    }

    /// Write Int16 frames to `file`. Returns false on any failure so the caller can flag the RIGHT stream
    /// (the mixed WAV vs the system-only sidecar) instead of one shared flag conflating them (audit LOW).
    @discardableResult
    private func write(_ frames: [Int32], to file: AVAudioFile) -> Bool {
        guard !frames.isEmpty else { return true }
        guard let buf = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(frames.count)),
              let dst = buf.int16ChannelData else { return false }
        buf.frameLength = AVAudioFrameCount(frames.count)
        for i in 0..<frames.count { dst[0][i] = Int16(clamping: frames[i]) }
        do { try file.write(from: buf); return true } catch { return false }
    }

    private func reportLevel(_ samples: [Int16]) {
        let n = samples.count; guard n > 0 else { return }
        var sum: Float = 0
        for s in samples { let f = Float(s) / 32_768; sum += f * f }
        onLevel(min(1, sqrt(sum / Float(n)) * 4))
    }

    private func publishMicState(_ state: MicState) {
        guard lastMicState != state else { return }
        lastMicState = state
        onMicState?(state)
    }

    private func applyMicGateControlChange() {
        let outcome = micGate.control(forceMuted: forceMuted())
        micGate = outcome.gate
        publishMicState(outcome.decision.state)
        if outcome.decision.state == .silent || outcome.decision.state == .muted {
            micConverter = nil
        }
    }

    private func forceMuted() -> Bool {
        forceMuteLock.withLock { forceMutedStorage }
    }

    private func containsSpeech(in samples: [Int16]) -> Bool {
        let waveform = samples.map { Float($0) / 32_768 }
        #if canImport(WhisperKit)
        return vad.voiceActivity(in: waveform).contains(true)
        #else
        return Self.energyVoiceActivity(in: waveform).contains(true)
        #endif
    }

    /// Fallback mirror of WhisperKit.EnergyVAD's 0.1s RMS frame check, used only if this target
    /// cannot import WhisperKit directly from the package graph.
    private static func energyVoiceActivity(in waveform: [Float],
                                            frameLengthSamples: Int = 1_600,
                                            energyThreshold: Float = 0.008) -> [Bool] {
        guard !waveform.isEmpty, frameLengthSamples > 0 else { return [] }
        let frameCount = Int((Double(waveform.count) / Double(frameLengthSamples)).rounded(.up))
        return (0..<frameCount).map { frameIndex in
            let start = frameIndex * frameLengthSamples
            let end = min(start + frameLengthSamples, waveform.count)
            return rmsEnergy(waveform[start..<end]) > energyThreshold
        }
    }

    private static func rmsEnergy(_ samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(Float(0)) { partial, sample in partial + sample * sample }
        return sqrt(sum / Float(samples.count))
    }
}

/// Live meeting recording — captures mic (+ system audio when Screen Recording is granted),
/// mixes them on a shared timeline into a 16 kHz mono WAV, then hands the file to the SAME
/// transcription pipeline that imports use.
@MainActor
@Observable
final class AudioCapture {

    enum CaptureError: LocalizedError {
        case micDenied, engineFailed(String)
        var errorDescription: String? {
            switch self {
            case .micDenied: "Microphone access is off. Enable it in System Settings → Privacy & Security → Microphone."
            case .engineFailed(let m): "Couldn't start recording — \(m)"
            }
        }
    }

    private(set) var isRecording = false
    private(set) var level: Float = 0
    private(set) var micState: MicState = .off
    private(set) var startedAt: Date?
    /// True after `stop()` if a file write failed mid-recording (the WAV may be truncated) — the
    /// model surfaces a soft warning but still processes the audio that WAS captured.
    private(set) var lastRecordingIncomplete = false
    /// Warning after `stop()` if system-audio capture was requested but did not produce usable samples.
    private(set) var lastSystemAudioWarning: String?
    private(set) var systemAudioState: SystemAudioCaptureState = .off
    private(set) var live = LiveAudioBuffers()
    var includeSystemAudio = true

    /// Whether system audio (the other participants) actually produced samples during this recording — the
    /// honest "we really captured the call's audio" signal, distinct from `includeSystemAudio` (only the
    /// request; ScreenCaptureKit can still fail or yield no samples). Read it BEFORE `stop()` clears it.
    /// Gates Meet-caption harvest so a mic-only recording can't steal a background call's captions (audit MED).
    var didCaptureCallAudio: Bool { systemAudioReceivedSamples }

    private let engine = AVAudioEngine()
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                                             channels: 1, interleaved: true)!
    private let liveObserverQueue = DispatchQueue(label: "callbrain.rec.live-observer", qos: .utility)
    private var writer: RecordingWriter?
    private var systemAudio: SystemAudioCapture?
    private var systemAudioReceivedSamples = false
    private var systemAudioWatchdog: Task<Void, Never>?
    private var meetMuted = false
    var micGateEnabled = true {
        didSet {
            writer?.setGateEnabled(micGateEnabled)
            if !isRecording { micState = .off }
        }
    }

    static func micAuthorized() -> Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
    static func requestMic() async -> Bool {
        if micAuthorized() { return true }
        return await AVCaptureDevice.requestAccess(for: .audio)
    }

    func start() async throws {
        guard !isRecording else { return }
        guard await Self.requestMic() else { throw CaptureError.micDenied }

        let input = engine.inputNode
        let inFormat = input.inputFormat(forBus: 0)
        guard inFormat.sampleRate > 0 else { throw CaptureError.engineFailed("no audio input device") }

        live = LiveAudioBuffers()
        lastRecordingIncomplete = false
        lastSystemAudioWarning = nil
        systemAudioState = includeSystemAudio ? .starting : .off
        systemAudioReceivedSamples = false
        systemAudioWatchdog?.cancel()
        systemAudioWatchdog = nil
        micState = meetMuted ? .muted : (micGateEnabled ? .silent : .off)
        let live = live
        // Level updates hop to the main actor (a plain Float is Sendable — safe + cheap).
        let w = RecordingWriter(
            target: targetFormat,
            micSourceRate: inFormat.sampleRate,
            gateEnabled: micGateEnabled,
            writeSystemSidecar: includeSystemAudio,   // T3: capture a clean remote-only channel for diarization
            onMicSamples: { [liveObserverQueue] samples, t in
                let live = live
                liveObserverQueue.async { live.append(.you, samples, atNanos: t) }
            },
            onSystemSamples: { [liveObserverQueue] samples, t in
                let live = live
                liveObserverQueue.async { live.append(.them, samples, atNanos: t) }
            },
            onMicState: { [weak self] state in
                Task { @MainActor in self?.micState = state }
            }
        ) { [weak self] lvl in
            Task { @MainActor in self?.level = lvl }
        }
        guard let w else { throw CaptureError.engineFailed("couldn't create the recording file") }
        writer = w
        w.setForceMuted(meetMuted)

        // The tap runs on the audio thread: it only extracts channel-0 floats + a monotonic
        // timestamp and hands them to the writer queue. No conversion, no file I/O, no lock here.
        // MUST be @Sendable: `start()` is @MainActor, so an un-annotated tap closure inherits
        // MainActor isolation and CRASHES (EXC_BREAKPOINT via swift_task_isCurrentExecutor →
        // dispatch_assert_queue_fail) the instant AVAudioEngine invokes it on the real-time audio
        // thread. @Sendable makes it non-isolated so it runs correctly off-main.
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { @Sendable buffer, when in
            // The buffer's own capture time on the mach clock (falls back to now if unavailable).
            let t = when.isHostTimeValid ? hostTicksToNanos(when.hostTime) : DispatchTime.now().uptimeNanoseconds
            guard let ch = buffer.floatChannelData else { return }
            let n = Int(buffer.frameLength)
            w.ingestMic(Array(UnsafeBufferPointer(start: ch[0], count: n)), atNanos: t)
        }
        engine.prepare()
        do { try engine.start() }
        catch {
            input.removeTap(onBus: 0)
            writer = nil
            micState = .off
            systemAudioState = .off
            throw CaptureError.engineFailed(error.localizedDescription)
        }

        isRecording = true; startedAt = Date()
        if includeSystemAudio {
            let sys = SystemAudioCapture(
                target: targetFormat,
                onState: { [weak self] state in
                    Task { @MainActor in self?.updateSystemAudioState(state) }
                },
                onSamples: { [weak self] samples, t in
                    w.ingestSystem(samples, atNanos: t)
                    Task { @MainActor in self?.markSystemAudioSamplesReceived() }
                }
            )
            systemAudio = sys
            await sys.startBestEffort()
        }
    }

    func stop() async -> URL? {
        guard isRecording else { return nil }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        systemAudioWatchdog?.cancel()
        systemAudioWatchdog = nil
        let finalSystemAudioState = systemAudioState
        await systemAudio?.stop()
        systemAudio = nil
        isRecording = false; level = 0; micState = .off; startedAt = nil; systemAudioState = .off
        let url = writer?.close()
        lastRecordingIncomplete = writer?.writeFailed ?? false
        lastSystemAudioWarning = SystemAudioHealth.stopWarning(
            includeSystemAudio: includeSystemAudio,
            state: finalSystemAudioState
        )
        systemAudioReceivedSamples = false
        writer = nil
        return url
    }

    /// Mirror the external meeting mute state into the writer. Muted input is still metered but
    /// is never mixed or retained for pre-roll.
    func setMeetMuted(_ muted: Bool) {
        meetMuted = muted
        if isRecording { micState = muted ? .muted : (micGateEnabled ? .silent : .off) }
        writer?.setForceMuted(muted)
    }

    private func updateSystemAudioState(_ state: SystemAudioCaptureState) {
        guard includeSystemAudio || state == .off else { return }
        if systemAudioReceivedSamples && (state == .starting || state == .capturing) { return }
        systemAudioState = state
        switch state {
        case .capturing:
            scheduleSystemAudioWatchdog()
        case .failed, .off:
            systemAudioWatchdog?.cancel()
            systemAudioWatchdog = nil
        case .receiving, .starting, .noSamples:
            break
        }
    }

    private func markSystemAudioSamplesReceived() {
        guard isRecording, includeSystemAudio else { return }
        systemAudioReceivedSamples = true
        systemAudioState = .receiving
    }

    private func scheduleSystemAudioWatchdog() {
        systemAudioWatchdog?.cancel()
        systemAudioWatchdog = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(8))
            } catch {
                return
            }
            self?.markSystemAudioNoSamplesIfNeeded()
        }
    }

    private func markSystemAudioNoSamplesIfNeeded() {
        systemAudioState = SystemAudioHealth.stateAfterWatchdog(
            includeSystemAudio: includeSystemAudio,
            current: systemAudioState,
            receivedSamples: systemAudioReceivedSamples
        )
    }
}
