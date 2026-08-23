import Foundation
@preconcurrency import AVFoundation

/// Single-feed token for the AVAudioConverter pull closure (a class ref instead of a captured
/// mutable var, so the pull closure doesn't warn).
private final class ConvertOnce: @unchecked Sendable { var fed = false }

/// Owns the output file + a time-aligned MIX of the mic and system-audio streams, and does ALL
/// heavy work on ONE private serial queue — never on the real-time audio threads. The audio
/// callbacks only extract plain sample arrays (Sendable) + a monotonic timestamp and hand them
/// over; conversion, mixing, and file I/O happen on the writer queue. This fixes two P1-audit
/// HIGHs at once: (1) mic + system audio are SUMMED on a shared timeline (not concatenated into
/// an incoherent file), and (2) the audio callback never blocks on disk I/O or a cross-stream
/// lock. Only `[Float]`/`[Int16]`/`UInt64`/`Double` cross a thread boundary, so there is no
/// data race on a non-Sendable AVAudioPCMBuffer.
///
/// Relocated verbatim from `AudioCapture.RecordingWriter` (executable target → library target) so
/// the mix/place/flush/sidecar logic is unit-testable via a synthetic `FrameSource`. The ONLY
/// surface changes vs the original: explicit output URLs (prod passes the real Recordings paths,
/// tests pass a temp dir), an injectable `EnergyVADGate` (drops the WhisperKit dependency), a
/// low-level `ingestMixSamples(_:atNanos:isMic:)` primitive, and `flushPending()`. The serial
/// queue, 2 s flush window, and all place/mix/flush/sidecar arithmetic are unchanged.
public final class AudioMixWriter: @unchecked Sendable {
    private let q = DispatchQueue(label: "callbrain.rec.writer", qos: .userInitiated)
    private var file: AVAudioFile?
    /// The remote-participants-only (system audio) sibling, written frame-aligned with the mixed WAV so the
    /// post-call pass can diarize a CLEAN remote channel for group attribution (T3). nil when not capturing
    /// system audio, or if the file couldn't be created — either way the pipeline falls back to mono.
    private var systemFile: AVAudioFile?
    public private(set) var systemURL: URL?
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
    public let url: URL

    // Crash-proof checkpoint tee (W1b). Invoked at the END of every `flush(upTo:)` with EXACTLY the
    // clamped Int16 frames just written to the main WAV, so a `RecordingCheckpointWriter` can persist
    // rolling segments. Backed on the writer queue: `flush` (always on `q`) reads `_onFlushedFrames`
    // directly; external callers set it via the public accessor (a brief `q.sync`) before ingest
    // begins, so there is no data race and the mix path is untouched when it's nil.
    private var _onFlushedFrames: (@Sendable ([Int16]) -> Void)?
    public var onFlushedFrames: (@Sendable ([Int16]) -> Void)? {
        get { q.sync { _onFlushedFrames } }
        set { q.sync { _onFlushedFrames = newValue } }
    }

    // Mix accumulator. `acc[i]` holds absolute frame (accBase + i), summed in Int32 so two Int16
    // streams add without mid-mix clipping (clamped to Int16 only on flush). Bounded by a ~1s
    // flush window: anything older than the newest frame minus the window can't still be waiting
    // on a late buffer from the other stream, so it's written and dropped from memory.
    private var acc: [Int32] = []
    private var accBase: Int64 = 0             // absolute frame index of acc[0]
    private var startNanos: UInt64 = 0         // first buffer's capture clock (0 = unset)
    private var lastMicEndFrame: Int64 = 0     // highest absolute frame written by the mic stream
    public private(set) var writeFailed = false       // a MIXED-file write threw → the WAV may be truncated
    private var systemWriteFailed = false      // a SYSTEM-sidecar write failed → abandon it (no dual channel)
    private static let flushWindowFrames: Int64 = 32_000   // ~2s @16k — covers inter-stream skew
    private var micGate: MicGate
    private var lastMicState: MicState?
    private let forceMuteLock = NSLock()
    private var forceMutedStorage = false
    // Primary speech detector (default `SpectralVADGate`): a low-latency energy+spectral gate that
    // keeps the founder's QUIET speech the old crude 0.008 RMS gate dropped, while still gating true
    // silence / low hum. Injected via the init so tests can swap it; the field is the protocol type.
    private let vad: any VoiceActivityDetector
    // Guaranteed FALLBACK: the shipped 0.008 energy gate. `containsSpeech` OR-s it in so the recorder
    // is NEVER less permissive than what shipped — a real onset is never dropped (record-when-unsure),
    // even if the primary detector ever regressed below the energy floor.
    private let energyFallback = EnergyVADGate()

    public init?(mixURL: URL,
                 systemSidecarURL: URL?,
                 target: AVAudioFormat,
                 micSourceRate: Double,
                 gateEnabled: Bool = true,
                 vad: any VoiceActivityDetector = SpectralVADGate(),
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
        self.vad = vad
        self.onMicSamples = onMicSamples
        self.onSystemSamples = onSystemSamples
        self.onMicState = onMicState
        self.onLevel = onLevel
        // Output paths are passed in by the caller: prod hands the durable Recordings paths
        // (Application Support/CallBrain/Recordings) that `RecordingStorage` owns; tests hand a temp dir.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        // processingFormat MUST match the Int16 buffers we write (`target`), else AVAudioFile defaults
        // its processingFormat to Float32 and `write(from:)` trips a CoreAudio ExtAudioFile assertion
        // (EXC_BREAKPOINT / CAAssertRtn) on the first flush — crash report Recap-2026-07-05-123922.
        guard let f = try? AVAudioFile(forWriting: mixURL, settings: settings,
                                       commonFormat: .pcmFormatInt16, interleaved: true) else { return nil }
        file = f; url = mixURL
        // Open the system-only sibling when we're capturing the other participants (T3). Best-effort: if it
        // can't be created we just skip dual-channel — the mixed WAV (and mono transcription) is unaffected.
        if let systemSidecarURL {
            if let sf = try? AVAudioFile(forWriting: systemSidecarURL, settings: settings,
                                         commonFormat: .pcmFormatInt16, interleaved: true) {
                systemFile = sf; systemURL = systemSidecarURL
            }
        }
    }

    /// Force the mic gate closed from another thread. The flag is lock-guarded; the state machine
    /// itself still advances only on `q`.
    public func setForceMuted(_ muted: Bool) {
        forceMuteLock.withLock { forceMutedStorage = muted }
        q.async { [weak self] in self?.applyMicGateControlChange() }
    }

    /// Toggle VAD gating. When disabled, the mic path emits every converted buffer unless the
    /// external force-mute override is active.
    public func setGateEnabled(_ enabled: Bool) {
        q.async { [weak self] in
            guard let self else { return }
            micGate = micGate.settingGateEnabled(enabled)
            applyMicGateControlChange()
        }
    }

    // MARK: - ingest (called from audio threads — cheap, non-blocking)

    /// Mic samples, channel 0, at the engine's native rate. Converted + mixed on the queue.
    public func ingestMic(_ samples: [Float], atNanos t: UInt64) {
        guard !samples.isEmpty else { return }
        q.async { [weak self] in self?.mixMic(samples, t) }
    }

    /// Low-level ingest for samples already at the target rate (Int16 16k mono): drives
    /// place/mix/flush/sidecar directly with NO resampler, gate, VAD, or hardware. Real capture
    /// backends push mic via `ingestMic` and system via `ingestSystem`; a synthetic `FrameSource`
    /// pull-drives THIS entry so the same writer runs deterministically with no hardware.
    public func ingestMixSamples(_ samples: [Int16], atNanos t: UInt64, isMic: Bool) {
        guard !samples.isEmpty else { return }
        q.async { [weak self] in self?.mix(samples, at: t, isMic: isMic) }
    }

    /// System audio, already resampled to the target (Int16 16k mono) by SystemAudioCapture.
    public func ingestSystem(_ samples: [Int16], atNanos t: UInt64) {
        guard !samples.isEmpty else { return }
        ingestMixSamples(samples, atNanos: t, isMic: false)
        onSystemSamples?(samples, t)
    }

    /// Finalize (write to disk) everything currently buffered WITHOUT closing the file, so a
    /// checkpoint tee can persist a consistent segment mid-recording. Uses the SAME window-flush
    /// arithmetic as the periodic flush (mixed WAV + index-aligned sidecar); the file stays open
    /// for continued ingest.
    public func flushPending() {
        q.sync { flush(upTo: accBase + Int64(acc.count)) }
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
        // The exact Int32 mix window the main WAV receives — captured before `removeFirst` so the
        // checkpoint tee below can clamp the SAME buffer to Int16 (parity with what the WAV got).
        let mixedInt32 = Array(acc[0..<count])
        if !write(mixedInt32, to: file) { writeFailed = true }
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
        // Tee the EXACT clamped Int16 frames the main WAV received to the checkpoint (W1b). One
        // non-blocking closure call — the checkpoint writer's own queue absorbs the I/O — and zero
        // overhead (no clamp, no call) when no checkpoint is wired. Runs on `q`, so it reads the
        // backing store directly.
        if let onFlushedFrames = _onFlushedFrames {
            onFlushedFrames(mixedInt32.map { Int16(clamping: $0) })
        }
    }

    /// Drain the converter tail + write everything still buffered, then close the file.
    @discardableResult
    public func close() -> URL {
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
        // Primary detector first (catches quiet voiced speech the energy floor misses). If it reads
        // no-speech, fall back to the shipped 0.008 energy gate so we never drop what it would have
        // kept — bias to record-when-unsure. The fallback runs only on primary-negative buffers.
        if vad.voiceActivity(in: waveform).contains(true) { return true }
        return energyFallback.voiceActivity(in: waveform).contains(true)
    }
}
