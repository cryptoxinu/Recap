import Foundation
import Darwin
import os
import CallBrainCore

/// Live transcriber that runs WhisperKit in a PERSISTENT child process (`cbtranscribe --serve`), keeping the
/// model warm for the ~1.5s live cadence while ISOLATING CoreML crashes: if the child dies (a CoreML/
/// GreedyTokenSampler assertion) or wedges, the round-trip fails, we tear it down, re-spawn, and — after a
/// failure — DEGRADE to a lighter, more reliable model. The host app is never taken down; the worst case is a
/// momentarily blank live transcript.
///
/// TWO SEPARATE TIMEOUTS — this is the fix for the watchdog-kill-during-cold-load bug that left the live
/// transcript blank for entire calls:
/// - `loadTimeout` — a GENEROUS budget for the child's COLD model-load, applied to the FIRST round-trip after
///   a spawn (which is the one that waits on `cbtranscribe`'s model load). Cold-loading `small.en`/`base`
///   under real in-app load (AVAudioEngine + ScreenCaptureKit + Ollama + a post-call ANE pass) routinely
///   takes far longer than a few seconds; the previous single 15s timer conflated load + inference and
///   SIGTERM'd the child mid-load every 15s, forever, so it never produced a single window.
/// - `perWindowTimeout` — a SHORT budget for one inference on the ALREADY-WARM model.
///
/// And a model FALLBACK LADDER (mirrors the post-call `runSidecarWithModelFallback`): a cold-load failure, or
/// repeated warm failures, degrades to the next lighter model (`small.en → base → tiny`), so a model that
/// traps in CoreML's MLTensor sampler, fails to load, or is too heavy to stay responsive is replaced instead
/// of blindly re-spawned. The ladder RESETS at record-stop (`shutdown`) so one bad call never pins the whole
/// app session to a degraded model.
///
/// Follows the codebase's @unchecked-Sendable + serial-queue + watchdog pattern for CLI children.
public final class SidecarLiveTranscriber: Transcriber, @unchecked Sendable {
    public nonisolated let modelID: String
    private let executableURL: URL
    private let models: [String]
    private let loadTimeout: TimeInterval
    private let perWindowTimeout: TimeInterval
    private let degradeAfter: Int
    private let queue = DispatchQueue(label: "cb.live.sidecar")
    private let log = Logger(subsystem: "com.callbrain", category: "live")

    private var process: Process?
    private var toChild: FileHandle?
    private var fromChild: FileHandle?
    private var modelIndex = 0
    private var isWarm = false               // false right after spawn; true after the first OK round-trip
    private var consecutiveFailures = 0

    /// A copy of the current child, readable OFF the serial `queue` so `shutdown()` can terminate it
    /// out-of-band. Without this, a `shutdown()` enqueued behind a round-trip that is blocked in `readExactly`
    /// for up to `loadTimeout` would leave the child (model resident on CPU/ANE) alive for up to a minute
    /// after record-stop — violating "nothing resident once a call ends" and stalling the next recording.
    private let ctrlLock = NSLock()
    private var liveProcess: Process?

    /// Writing to a CLI child that already exited must never deliver a process-killing SIGPIPE — it should
    /// surface as an EPIPE throw we can catch. Ignoring SIGPIPE process-wide is the standard, harmless posture
    /// for an app that spawns child processes (codex/claude/cbtranscribe). Runs once.
    private static let ignoreSIGPIPE: Void = { signal(SIGPIPE, SIG_IGN); return () }()

    public init(executableURL: URL, models: [String],
                loadTimeout: TimeInterval = 60, perWindowTimeout: TimeInterval = 12, degradeAfter: Int = 2) {
        _ = Self.ignoreSIGPIPE
        self.executableURL = executableURL
        // Preferred model first, then always append the crash-resistant base + tiny as final fallbacks
        // (deduped, order-preserving). `base` is proven fast-loading and MLTensor-crash-resistant here.
        var ladder: [String] = []
        for m in models + ["openai_whisper-base", "openai_whisper-tiny"] where !m.isEmpty && !ladder.contains(m) {
            ladder.append(m)
        }
        self.models = ladder.isEmpty ? ["openai_whisper-base"] : ladder
        self.modelID = self.models[0]
        self.loadTimeout = loadTimeout
        self.perWindowTimeout = perWindowTimeout
        self.degradeAfter = max(1, degradeAfter)
    }

    /// Back-compat single-model init (ladder = model → base → tiny).
    public convenience init(executableURL: URL, model: String, perWindowTimeout: TimeInterval = 12) {
        self.init(executableURL: executableURL, models: [model], perWindowTimeout: perWindowTimeout)
    }

    /// Spawn the child early so the model starts cold-loading before the first live window arrives. The load
    /// itself is covered by the FIRST round-trip's `loadTimeout`, so this is best-effort (never blocks long).
    public func prewarm() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async { [self] in _ = ensureRunningLocked(); cont.resume() }
        }
    }

    public func transcribe(_ samples: [Float],
                           progress: @Sendable @escaping (Double) -> Void) async throws -> [TranscribedSegment] {
        guard !samples.isEmpty else { return [] }
        return await withCheckedContinuation { (cont: CheckedContinuation<[TranscribedSegment], Never>) in
            queue.async { [self] in cont.resume(returning: roundTripLocked(samples)) }
        }
    }

    /// Release the warm child at record-stop. Terminates the child OUT OF BAND first (so an in-flight blocking
    /// read on the serial queue EOFs immediately and the queued teardown isn't starved behind a ~minute-long
    /// cold-load), then resets the fallback ladder so the NEXT recording starts fresh at the preferred model.
    public func shutdown() {
        ctrlLock.lock(); let p = liveProcess; liveProcess = nil; ctrlLock.unlock()
        if let p, p.isRunning { p.terminate() }
        queue.async { [self] in
            modelIndex = 0
            consecutiveFailures = 0
            teardownLocked()
        }
    }

    // MARK: - queue-serialized internals

    private enum Exchange { case ok(Data); case died; case wedged; case badFrame }

    /// NEVER throws. The FIRST round-trip after a spawn gets the long `loadTimeout` (it waits on the child's
    /// cold model-load); every subsequent one gets the short `perWindowTimeout`. A cold-load failure degrades
    /// immediately (a 60s timeout / a child that exits during load is strong evidence the model won't work
    /// here); warm failures degrade after `degradeAfter` in a row.
    private func roundTripLocked(_ samples: [Float]) -> [TranscribedSegment] {
        guard let proc = ensureRunningLocked() else {
            noteFailureLocked(reason: "spawn-failed", degradeNow: false); return []
        }
        let cold = !isWarm
        let timeout = cold ? loadTimeout : perWindowTimeout
        switch exchangeLocked(LiveServeProtocol.encodeRequest(samples), proc: proc, timeout: timeout) {
        case .ok(let json):
            let segs = (try? JSONDecoder().decode([TranscribedSegment].self, from: json)) ?? []
            noteSuccessLocked()
            return segs
        case .died:
            // A child that dies/exits DURING cold-load (incl. cbtranscribe exiting on a model-load failure)
            // is strong evidence this model won't work here → degrade now, don't burn more calls on it.
            noteFailureLocked(reason: cold ? "child-died-during-load" : "child-crashed", degradeNow: cold)
            return []
        case .wedged:
            noteFailureLocked(reason: cold ? "load-timeout" : "watchdog-wedged", degradeNow: cold)
            return []
        case .badFrame:
            noteFailureLocked(reason: "bad-frame", degradeNow: false)
            return []
        }
    }

    private func exchangeLocked(_ request: Data, proc: Process, timeout: TimeInterval) -> Exchange {
        guard let inp = toChild, let outp = fromChild else { return .died }
        // After the deadline, terminate the child (SIGTERM) → the blocking read below EOFs; escalate to
        // SIGKILL only if it is STILL running (so we never signal a reaped/reused pid). Capturing `proc`
        // keeps it alive for that check. Cancelled on normal completion. wedged-vs-died is classified from
        // ELAPSED time, not a shared mutable flag, so the watchdog (background) and this method (serial
        // queue) never race on state.
        let start = DispatchTime.now()
        let watchdog = DispatchWorkItem {
            proc.terminate()
            let pid = proc.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if proc.isRunning { kill(pid, SIGKILL) }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        defer { watchdog.cancel() }
        func hitDeadline() -> Bool {
            Double(DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds) / 1e9 >= timeout - 0.25
        }
        do {
            try inp.write(contentsOf: request)
        } catch {
            teardownLocked(); return .died   // EPIPE: child already gone
        }
        guard let lenData = LiveServeProtocol.readExactly(outp, 4),
              let len = LiveServeProtocol.decodeLength(lenData) else {
            let wedged = hitDeadline(); teardownLocked(); return wedged ? .wedged : .died
        }
        guard len > 0, len < 8_000_000, let json = LiveServeProtocol.readExactly(outp, len) else {
            let wedged = hitDeadline(); teardownLocked(); return wedged ? .wedged : (len == 0 ? .badFrame : .died)
        }
        return .ok(json)
    }

    private func ensureRunningLocked() -> Process? {
        if let p = process, p.isRunning, toChild != nil, fromChild != nil { return p }
        teardownLocked()
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else { return nil }
        let p = Process()
        p.executableURL = executableURL
        p.arguments = ["--serve", "--model", models[modelIndex]]
        let inPipe = Pipe(); let outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        // stderr is the child's diagnostics — let it inherit (nothing to drain/deadlock on).
        do { try p.run() } catch {
            log.error("live spawn failed model=\(self.models[self.modelIndex], privacy: .public) err=\(error.localizedDescription, privacy: .public)")
            return nil
        }
        process = p
        ctrlLock.lock(); liveProcess = p; ctrlLock.unlock()
        isWarm = false
        let writeHandle = inPipe.fileHandleForWriting
        // Writing to a child that already died must throw EPIPE (→ caught → empty window), NOT deliver a
        // process-killing SIGPIPE. Set it per-fd so we don't touch global signal handling.
        fcntl(writeHandle.fileDescriptor, F_SETNOSIGPIPE, 1)
        toChild = writeHandle
        fromChild = outPipe.fileHandleForReading
        log.info("live spawn model=\(self.models[self.modelIndex], privacy: .public) pid=\(p.processIdentifier) — first window gets \(Int(self.loadTimeout))s load budget")
        return p
    }

    private func teardownLocked() {
        if let p = process, p.isRunning { p.terminate() }
        try? toChild?.close()
        try? fromChild?.close()
        process = nil; toChild = nil; fromChild = nil
        isWarm = false
        ctrlLock.lock(); liveProcess = nil; ctrlLock.unlock()
    }

    private func noteSuccessLocked() {
        if !isWarm {
            log.info("live serve ready + first window ok model=\(self.models[self.modelIndex], privacy: .public)")
        }
        isWarm = true
        consecutiveFailures = 0
    }

    /// A failure tears the child down (clean re-spawn next tick). It degrades to the next lighter model when
    /// `degradeNow` (a cold-load failure) or after `degradeAfter` consecutive warm failures — defeating both
    /// the MLTensor crash-loop (child keeps dying) and the too-heavy/failed-load case, which blind same-model
    /// re-spawn never escaped.
    private func noteFailureLocked(reason: String, degradeNow: Bool) {
        consecutiveFailures += 1
        log.error("live round-trip failed reason=\(reason, privacy: .public) model=\(self.models[self.modelIndex], privacy: .public) consecutive=\(self.consecutiveFailures)")
        teardownLocked()
        if (degradeNow || consecutiveFailures >= degradeAfter), modelIndex < models.count - 1 {
            modelIndex += 1
            consecutiveFailures = 0
            log.error("live degrading to \(self.models[self.modelIndex], privacy: .public)")
        }
    }

    deinit {
        if let p = process, p.isRunning { p.terminate() }
    }
}
