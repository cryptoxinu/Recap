import Foundation
import Darwin
import CallBrainCore

/// Live transcriber that runs WhisperKit in a PERSISTENT child process (`cbtranscribe --serve`),
/// keeping the model warm for the ~1.5s live cadence while ISOLATING CoreML crashes: if the child
/// dies (a CoreML/GreedyTokenSampler assertion) or wedges, the round-trip fails, we tear it down,
/// return an empty window, and re-spawn on the next call. The Recap process is never taken down
/// and the recording is untouched — the worst case is a momentarily blank live transcript. This is
/// the whole point of the boundary: the same in-process call path used to crash the app mid-meeting.
///
/// Follows the codebase's @unchecked-Sendable + serial-queue + watchdog pattern for CLI children.
public final class SidecarLiveTranscriber: Transcriber, @unchecked Sendable {
    public nonisolated let modelID: String
    private let executableURL: URL
    private let model: String
    private let perWindowTimeout: TimeInterval
    private let queue = DispatchQueue(label: "cb.live.sidecar")
    private var process: Process?
    private var toChild: FileHandle?
    private var fromChild: FileHandle?

    /// Writing to a CLI child that already exited must never deliver a process-killing SIGPIPE — it
    /// should surface as an EPIPE throw we can catch. Ignoring SIGPIPE process-wide is the standard,
    /// harmless posture for an app that spawns child processes (codex/claude/cbtranscribe). Runs once.
    private static let ignoreSIGPIPE: Void = { signal(SIGPIPE, SIG_IGN); return () }()

    public init(executableURL: URL, model: String, perWindowTimeout: TimeInterval = 15) {
        _ = Self.ignoreSIGPIPE
        self.executableURL = executableURL
        self.model = model
        self.modelID = model
        self.perWindowTimeout = perWindowTimeout
    }

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

    /// Release the warm child (record-stop → "nothing resident once a call ends"). Re-spawns on next use.
    public func shutdown() {
        queue.async { [self] in teardownLocked() }
    }

    /// Runs on `queue` (serialized). NEVER throws — a dead/wedged child degrades to an empty window.
    private func roundTripLocked(_ samples: [Float]) -> [TranscribedSegment] {
        guard let (inp, outp, proc) = ensureRunningLocked() else { return [] }
        // A wedged (not crashed) child must not hang the live loop. After the deadline, SIGTERM its pid,
        // which EOFs the blocking read below. The watchdog is cancelled on normal completion, so it only
        // fires for a genuinely stuck, still-alive child — making pid reuse effectively impossible.
        let pid = proc.processIdentifier
        // SIGTERM, then escalate to SIGKILL if the child ignores it, so a hard-wedged child can't keep
        // the serial queue blocked in read/write forever (audit MED).
        let watchdog = DispatchWorkItem {
            kill(pid, SIGTERM)
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { kill(pid, SIGKILL) }
        }
        // MUST be a different queue — `queue` is serial and is about to block on the read below.
        DispatchQueue.global().asyncAfter(deadline: .now() + perWindowTimeout, execute: watchdog)
        defer { watchdog.cancel() }
        do {
            try inp.write(contentsOf: LiveServeProtocol.encodeRequest(samples))
            guard let lenData = LiveServeProtocol.readExactly(outp, 4),
                  let len = LiveServeProtocol.decodeLength(lenData), len > 0, len < 8_000_000,
                  let json = LiveServeProtocol.readExactly(outp, len) else {
                teardownLocked(); return []
            }
            return (try? JSONDecoder().decode([TranscribedSegment].self, from: json)) ?? []
        } catch {
            teardownLocked(); return []
        }
    }

    private func ensureRunningLocked() -> (FileHandle, FileHandle, Process)? {
        if let p = process, p.isRunning, let i = toChild, let o = fromChild { return (i, o, p) }
        teardownLocked()
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else { return nil }
        let p = Process()
        p.executableURL = executableURL
        p.arguments = ["--serve", "--model", model]
        let inPipe = Pipe(); let outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        // stderr is the child's diagnostics — let it inherit (nothing to drain/deadlock on).
        do { try p.run() } catch { return nil }
        process = p
        let writeHandle = inPipe.fileHandleForWriting
        // Writing to a child that already died must throw EPIPE (→ caught → empty window), NOT deliver
        // a process-killing SIGPIPE. Set it per-fd so we don't touch global signal handling.
        fcntl(writeHandle.fileDescriptor, F_SETNOSIGPIPE, 1)
        toChild = writeHandle
        fromChild = outPipe.fileHandleForReading
        return (toChild!, fromChild!, p)
    }

    private func teardownLocked() {
        if let p = process, p.isRunning { p.terminate() }
        try? toChild?.close()
        try? fromChild?.close()
        process = nil; toChild = nil; fromChild = nil
    }

    deinit {
        if let p = process, p.isRunning { p.terminate() }
    }
}
