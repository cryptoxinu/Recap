import Foundation
@preconcurrency import AVFoundation
import CallBrainCore
import CallBrainAppCore

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
    private var writer: AudioMixWriter?
    /// Crash-proof checkpoint tee (W1b): rolling ~30 s WAV segments so a kill mid-recording can be
    /// recovered at launch. Additive — nil-safe, never alters the recording path.
    private var checkpoint: RecordingCheckpointWriter?
    /// The checkpoint directory name (== mix stem uuid) of the RUNNING recording, so launch recovery
    /// can exclude a live recording's own dir. nil whenever not recording.
    private(set) var activeCheckpointID: String?
    /// The active system-audio backend (protocol type so it can be either the ScreenCaptureKit path or
    /// the Core Audio process tap). Built via `SystemAudioBackendFactory` — in Phase B the effective
    /// default is `.screenCapture`, so this is a `SystemAudioCapture` unless the founder opted into the
    /// tap in Settings. The `onSamples`/`onState` wiring below is identical for both backends.
    private var systemAudio: SystemAudioBackend?
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

    /// - Parameter checkpointTitle: the founder's chosen title (if any) at start, stored in the crash
    ///   checkpoint manifest so a recovered recording is named well. Empty is fine (recovery falls back
    ///   to a timestamped default). Additive — default preserves the existing call shape.
    func start(checkpointTitle: String = "") async throws {
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
        // Same durable output paths RecordingStorage owns (Application Support/CallBrain/Recordings),
        // never the system temp dir; the sidecar is the hidden remote-only `.system.wav` sibling.
        let mixURL = RecordingStorage.directory()
            .appendingPathComponent("callbrain-rec-\(UUID().uuidString).wav")
        let sidecarURL = includeSystemAudio ? RecordingSidecars.systemAudioURL(forRecording: mixURL) : nil
        // Level updates hop to the main actor (a plain Float is Sendable — safe + cheap).
        // W1e ducking preference — OFF by default (a balanced mix is best for reviewing calls). Read
        // per-recording so a Settings toggle takes effect on the next recording. `bool(forKey:)`
        // returns false for the unset key, so the shipped default keeps the mix byte-identical.
        let micDominant = UserDefaults.standard.bool(forKey: AudioMixWriter.micDominantMixKey)
        let w = AudioMixWriter(
            mixURL: mixURL,
            systemSidecarURL: sidecarURL,   // T3: capture a clean remote-only channel for diarization
            target: targetFormat,
            micSourceRate: inFormat.sampleRate,
            gateEnabled: micGateEnabled,
            micDominantMix: micDominant,
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

        // Crash-proof checkpoints (W1b): tee the SAME already-mixed Int16 frames the main WAV gets
        // into rolling ~30 s segments under Recordings/.checkpoints/<mix-stem>/. The tee is a single
        // non-blocking `append` (its own serial queue absorbs I/O) so the mix queue never stalls. On a
        // clean stop the segments are redundant and deleted; a kill mid-call leaves them for recovery.
        let recordingID = mixURL.deletingPathExtension().lastPathComponent
        let ckpt = RecordingCheckpointWriter(
            checkpointsRoot: RecordingStorage.directory().appendingPathComponent(".checkpoints", isDirectory: true),
            recordingID: recordingID,
            title: checkpointTitle,
            startedAt: Date(),
            sampleRate: 16_000,
            now: Date()
        )
        checkpoint = ckpt
        activeCheckpointID = recordingID
        w.onFlushedFrames = { [ckpt] frames in ckpt.append(frames) }

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
            checkpoint?.finishClean(); checkpoint = nil; activeCheckpointID = nil   // no recording → drop the empty dir
            micState = .off
            systemAudioState = .off
            throw CaptureError.engineFailed(error.localizedDescription)
        }

        isRecording = true; startedAt = Date()
        if includeSystemAudio {
            // Pick the backend from the persisted preference (Phase B default resolves to SCKit, so
            // this is byte-for-byte today's behavior unless the founder opted into the tap in Settings).
            // The sink is identical for either backend — the SAME `w.ingestSystem` mix path.
            let sys = SystemAudioBackendFactory.make(
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
        // Clean stop → the main WAV is authoritative, so the checkpoint segments are redundant. Drain
        // the final tee'd append (close() fired one last flush) then delete the whole dir. Ordering:
        // close() BEFORE finishClean() so the final append is enqueued before finishClean's barrier.
        checkpoint?.finishClean(); checkpoint = nil; activeCheckpointID = nil
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
