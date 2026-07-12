import Foundation

// MARK: - LLM provider types (generation over the user's CLI subscriptions, docs/ARCHITECTURE.md §5)

public enum ProviderID: String, Sendable, Codable, CaseIterable { case claude, codex, ollama }

public struct TokenUsage: Sendable, Equatable, Codable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    public var cacheCreationTokens: Int
    public init(inputTokens: Int = 0, outputTokens: Int = 0,
                cacheReadTokens: Int = 0, cacheCreationTokens: Int = 0) {
        self.inputTokens = inputTokens; self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens; self.cacheCreationTokens = cacheCreationTokens
    }
}

public struct Completion: Sendable, Equatable {
    public var text: String
    public var provider: ProviderID
    public var model: String
    public var usage: TokenUsage
    public var costUSD: Double
    public var stopReason: String?
    public init(text: String, provider: ProviderID, model: String, usage: TokenUsage,
                costUSD: Double, stopReason: String? = nil) {
        self.text = text; self.provider = provider; self.model = model
        self.usage = usage; self.costUSD = costUSD; self.stopReason = stopReason
    }
}

public enum LLMError: Error, Sendable, Equatable {
    case notInstalled(String)
    case launchFailed(String)
    case timedOut(seconds: Int)
    case nonZeroExit(code: Int32, stderr: String)
    case providerError(subtype: String, detail: String)   // CLI ran but reported an error envelope
    case rateLimited(resetAt: Double?)
    case decodeFailed(String)
    case allProvidersFailed(String)
}

extension LLMError: LocalizedError {
    /// Human-readable cause so a user who simply hasn't started Ollama / installed the CLI sees a real
    /// message instead of the useless bridged Foundation string ("The operation couldn't be completed…").
    public var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "The AI CLI wasn't found — install Claude or Codex, or switch engines in Settings."
        case .launchFailed:
            return "Couldn't reach the AI engine. Is Ollama running, or your Claude/Codex CLI available?"
        case .timedOut(let seconds):
            return "The AI engine took too long to respond (over \(seconds)s). Try again."
        case .nonZeroExit:
            return "The AI engine exited with an error. Check that Claude/Codex/Ollama is available."
        case .providerError(_, let detail):
            return detail.isEmpty ? "The AI engine reported an error." : detail
        case .rateLimited:
            return "Rate limited — try again shortly."
        case .decodeFailed:
            return "Couldn't read the AI engine's response. Try again."
        case .allProvidersFailed:
            return "No AI engine responded — check that Claude, Codex, or Ollama is available."
        }
    }
}

/// One event on a streaming generation (perfection plan Task 3.2 — the audit's #1 product-killer
/// was 40-50s of buffered spinner). `.delta` = a text fragment as the model writes; `.done` = the
/// final validated Completion (its `text` is authoritative — always ≥ the concatenated deltas).
public enum StreamEvent: Sendable {
    /// The CLI produced its first output line — the subprocess is alive (spawnMS anchor).
    case ready
    case delta(String)
    case done(Completion)
}

/// A text-generation provider over the user's CLI subscription (claude / codex / a router over both).
/// The abstraction lets `AskEngine`/`AIImporter` flip providers and fall back transparently (Phase 5).
public protocol LLMProvider: Sendable {
    nonisolated var id: ProviderID { get }
    func complete(prompt: String, system: String?, model: String, timeout: TimeInterval) async throws -> Completion
    func completeJSON(prompt: String, system: String?, schema: String, model: String, timeout: TimeInterval) async throws -> String
    /// Streamed generation. MUST be a protocol requirement (not extension-only) so existentials
    /// dispatch dynamically to real implementations; the default is a buffered fallback.
    /// `timeout` is an INACTIVITY timeout for streaming implementations (plan §5.3 decision).
    func streamComplete(prompt: String, system: String?, model: String, timeout: TimeInterval) -> AsyncThrowingStream<StreamEvent, Error>
}

public extension LLMProvider {
    func complete(prompt: String, system: String? = nil) async throws -> Completion {
        try await complete(prompt: prompt, system: system, model: "sonnet", timeout: 120)
    }
    func completeJSON(prompt: String, system: String?, schema: String) async throws -> String {
        try await completeJSON(prompt: prompt, system: system, schema: schema, model: "sonnet", timeout: 180)
    }

    /// Buffered fallback: providers without token streaming still satisfy the streaming API —
    /// one `.done` at the end, no deltas. Router fallback semantics stay unchanged.
    func streamComplete(prompt: String, system: String?, model: String, timeout: TimeInterval) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let c = try await complete(prompt: prompt, system: system, model: model, timeout: timeout)
                    continuation.yield(.done(c))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// A provider that can ALSO research the open web (only the Claude CLI — Codex runs network-sandboxed).
/// Used ONLY for user-initiated "research online" requests, with just WebSearch+WebFetch enabled (no
/// shell/file tools), so injected transcript or web content can never trigger code execution.
public protocol WebResearchProvider: Sendable {
    func completeWithWeb(prompt: String, system: String?, model: String, timeout: TimeInterval) async throws -> Completion
}

// MARK: - Subprocess (Swift-6-clean: non-Sendable Process/Pipe live inside an @unchecked Sendable holder)

enum Subprocess {
    struct Output: Sendable { let stdout: String; let stderr: String; let exitCode: Int32 }
    private static let requiredPathPrefixes = [
        "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin",
        "\(NSHomeDirectory())/.local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
    ]

    /// A secret-bearing env var name that should NOT be inherited by a spawned CLI (defense-in-depth: the
    /// child is unsandboxed, so beyond the named `scrub` list we also strip anything that PATTERN-matches a
    /// credential — API keys, tokens, secrets, and provider redirect vars like ANTHROPIC_BASE_URL — so a
    /// secret in the launch environment can't leak to (or redirect) the child. Audit MED.
    static func isSecretEnvKey(_ key: String) -> Bool {
        let k = key.uppercased()
        if k == "GOOGLE_APPLICATION_CREDENTIALS" { return true }
        if k.hasPrefix("AWS_") { return true }
        for s in ["_API_KEY", "_ACCESS_KEY", "_SECRET_KEY", "_SECRET_ACCESS_KEY", "_TOKEN", "_SECRET",
                  "_BASE_URL", "_PASSWORD", "_CREDENTIALS", "_AUTH_TOKEN"] where k.hasSuffix(s) { return true }
        return false
    }

    /// Build the environment for spawned CLIs. Finder-launched macOS apps often inherit a tiny launchd
    /// PATH (`/usr/bin:/bin:/usr/sbin:/sbin`), but Homebrew `codex` is a Node shebang script and needs
    /// `/opt/homebrew/bin/node`. We repair PATH while preserving the security scrub.
    static func makeEnvironment(base: [String: String] = ProcessInfo.processInfo.environment,
                                scrub: [String] = [],
                                extraEnv: [String: String] = [:]) -> [String: String] {
        var env = base
        for k in scrub { env.removeValue(forKey: k) }
        env = env.filter { !Self.isSecretEnvKey($0.key) }
        env["PATH"] = repairedPath(env["PATH"])
        for (k, v) in extraEnv { env[k] = v }
        return env
    }

    private static func repairedPath(_ current: String?) -> String {
        var seen = Set<String>()
        var parts: [String] = []
        for p in requiredPathPrefixes + (current ?? "").split(separator: ":").map(String.init) {
            guard !p.isEmpty, seen.insert(p).inserted else { continue }
            parts.append(p)
        }
        return parts.joined(separator: ":")
    }

    /// Run `executable` with `args`, optionally piping `stdin`. Filters secret-bearing env vars (the `scrub`
    /// list PLUS pattern-matched credentials → forces CLI subscription auth + no secret leak), sets `cwd`,
    /// drains stdout+stderr concurrently (no pipe-buffer deadlock), and kills the child after `timeout`.
    static func run(executable: String, args: [String], stdin: String? = nil, cwd: String? = nil,
                    scrub: [String] = [], extraEnv: [String: String] = [:],
                    timeout: TimeInterval = 120) async throws -> Output {
        let h = ProcHolder()
        h.process.executableURL = URL(fileURLWithPath: executable)
        h.process.arguments = args
        if let cwd { h.process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        h.process.environment = makeEnvironment(scrub: scrub, extraEnv: extraEnv)
        h.process.standardOutput = h.out
        h.process.standardError = h.err
        h.process.standardInput = h.inp

        // If the surrounding Task is cancelled (the chat Stop button), terminate the CLI child so it stops
        // immediately instead of running to completion in the background.
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Output, Error>) in
            do { try h.process.run(); h.markLaunched() }
            catch {
                cont.resume(throwing: LLMError.launchFailed("\(executable): \(error.localizedDescription)"))
                return
            }

            // START THE DRAINS FIRST (Codex audit fix): with a large prompt, the child can emit stdout/
            // stderr while we're still writing stdin. Draining concurrently before the stdin write
            // prevents a pipe-buffer deadlock.
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global().async { h.outBuf.set(h.out.fileHandleForReading.readDataToEndOfFile()); group.leave() }
            group.enter()
            DispatchQueue.global().async { h.errBuf.set(h.err.fileHandleForReading.readDataToEndOfFile()); group.leave() }

            // Feed stdin on a BACKGROUND queue (Codex P5 gate MED): a synchronous write here would block
            // scheduling the watchdog if the child stops reading a large prompt — then the timeout never
            // arms and Ask hangs forever. Off-thread, the watchdog always arms.
            DispatchQueue.global().async {
                if let stdin { try? h.inp.fileHandleForWriting.write(contentsOf: Data(stdin.utf8)) }
                try? h.inp.fileHandleForWriting.close()
            }

            // Watchdog: SIGTERM at the deadline, then escalate to SIGKILL if the child ignores it, so a
            // wedged CLI can't keep `waitUntilExit` (and the whole call) blocked.
            let watchdog = DispatchWorkItem {
                guard h.process.isRunning else { return }
                h.timedOut.set()
                h.terminateIfRunning()
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) { h.killIfRunning() }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

            group.enter()
            DispatchQueue.global().async { h.process.waitUntilExit(); group.leave() }

            group.notify(queue: .global()) {
                watchdog.cancel()
                if h.timedOut.value {
                    cont.resume(throwing: LLMError.timedOut(seconds: Int(timeout)))
                } else {
                    cont.resume(returning: Output(stdout: h.outBuf.string,
                                                  stderr: h.errBuf.string,
                                                  exitCode: h.process.terminationStatus))
                }
            }
        }
        } onCancel: {
            // Stop button → SIGTERM, then escalate to SIGKILL if the child ignores it, so a wedged
            // CLI can't keep running (and burning quota) after cancel — matching the timeout +
            // streaming paths (audit C HIGH: buffered cancel was TERM-only).
            h.terminateIfRunning()
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { h.killIfRunning() }
        }
    }

    /// Streaming variant (Task 3.2): yields raw stdout CHUNKS as they arrive. Same env scrub,
    /// stderr drained concurrently (freeze-history: an undrained 64KB stderr deadlocks the child),
    /// INACTIVITY watchdog (reset on every chunk — a thinking model that streams slowly is fine;
    /// a wedged one is killed), and consumer cancellation terminates the child (quota leak guard).
    /// On clean EOF the stream finishes; a non-zero exit surfaces as providerError with stderr.
    static func stream(executable: String, args: [String], stdin: String? = nil, cwd: String? = nil,
                       scrub: [String] = [], extraEnv: [String: String] = [:],
                       inactivityTimeout: TimeInterval = 60) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let h = ProcHolder()
            h.process.executableURL = URL(fileURLWithPath: executable)
            h.process.arguments = args
            if let cwd { h.process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
            h.process.environment = makeEnvironment(scrub: scrub, extraEnv: extraEnv)
            h.process.standardOutput = h.out
            h.process.standardError = h.err
            h.process.standardInput = h.inp

            continuation.onTermination = { _ in
                h.terminateIfRunning()
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) { h.killIfRunning() }
            }

            do { try h.process.run(); h.markLaunched() }
            catch {
                continuation.finish(throwing: LLMError.launchFailed("\(executable): \(error.localizedDescription)"))
                return
            }

            // Inactivity watchdog — re-armed on every stdout chunk (lock-guarded class: Swift 6
            // strict concurrency forbids capturing a local var/closure across @Sendable bounds).
            let watchdog = InactivityWatchdog(interval: inactivityTimeout) {
                h.timedOut.set()
                h.terminateIfRunning()
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) { h.killIfRunning() }
            }
            watchdog.arm()

            // Drain stderr concurrently into a buffer (never to the consumer).
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global().async { h.errBuf.set(h.err.fileHandleForReading.readDataToEndOfFile()); group.leave() }

            // Feed stdin off-thread, then close (same deadlock-avoidance as run()).
            DispatchQueue.global().async {
                if let stdin { try? h.inp.fileHandleForWriting.write(contentsOf: Data(stdin.utf8)) }
                try? h.inp.fileHandleForWriting.close()
            }

            // Stream stdout chunks. readabilityHandler fires on the handle's own thread.
            // Total-bytes cap (Codex phase-3 MED): AsyncThrowingStream buffers unboundedly — a
            // runaway child must die instead of growing memory. 16MB ≫ any real answer envelope.
            let stdoutHandle = h.out.fileHandleForReading
            group.enter()
            let stdoutDone = FlagBox()
            let byteCount = CounterBox()
            let oversized = FlagBox()
            stdoutHandle.readabilityHandler = { fh in
                let chunk = fh.availableData
                if chunk.isEmpty {   // EOF
                    fh.readabilityHandler = nil
                    if !stdoutDone.value { stdoutDone.set(); group.leave() }
                    return
                }
                if byteCount.add(chunk.count) > 16 * 1024 * 1024 {
                    fh.readabilityHandler = nil
                    oversized.set()
                    h.terminateIfRunning()   // TERM, then KILL if ignored (round-2 MED: a child
                    DispatchQueue.global().asyncAfter(deadline: .now() + 3) { h.killIfRunning() }
                    if !stdoutDone.value { stdoutDone.set(); group.leave() }
                    return
                }
                watchdog.arm()
                continuation.yield(chunk)
            }

            group.enter()
            DispatchQueue.global().async { h.process.waitUntilExit(); group.leave() }

            group.notify(queue: .global()) {
                watchdog.cancel()
                if oversized.value {
                    // Honest error — not a timeout (round-2 MED: the UI copy must not lie).
                    continuation.finish(throwing: LLMError.providerError(
                        subtype: "oversized_output",
                        detail: "The AI engine produced more than 16MB of output — stopped."))
                } else if h.timedOut.value {
                    continuation.finish(throwing: LLMError.timedOut(seconds: Int(inactivityTimeout)))
                } else if h.process.terminationStatus != 0 {
                    // A non-zero streaming exit with NO parsed error envelope is a TRANSIENT failure
                    // (pre-token rate limit, CLI crash, blip) — throw `.nonZeroExit` so the router
                    // falls back to the other subscription, exactly like the buffered path. Throwing
                    // `.providerError` here dead-ended it, since the router (correctly) never falls
                    // back on a deterministic providerError (audit C HIGH). A REAL CLI error envelope
                    // in the stream already surfaced as `.providerError` via the JSON parser upstream.
                    continuation.finish(throwing: LLMError.nonZeroExit(
                        code: h.process.terminationStatus,
                        stderr: String(h.errBuf.string.suffix(400))))
                } else {
                    continuation.finish()
                }
            }
        }
    }
}

/// Resettable inactivity timer for streaming subprocesses — lock-guarded so the readability
/// handler (its own thread) and completion paths can arm/cancel concurrently.
final class InactivityWatchdog: @unchecked Sendable {
    private let lock = NSLock()
    private var item: DispatchWorkItem?
    private var generation = 0
    private let queue = DispatchQueue(label: "cb.stream.watchdog")
    private let interval: TimeInterval
    private let onFire: @Sendable () -> Void
    init(interval: TimeInterval, onFire: @escaping @Sendable () -> Void) {
        self.interval = interval; self.onFire = onFire
    }
    func arm() {
        lock.lock(); defer { lock.unlock() }
        item?.cancel()
        generation += 1
        let gen = generation
        // Generation guard (audit C MED): a work item already DEQUEUED can't be cancelled and would
        // otherwise fire AFTER a fresh chunk re-armed the timer, killing a healthy stream. It runs,
        // but no-ops unless it's still the current generation.
        let w = DispatchWorkItem { [weak self, onFire] in
            guard let self else { return }
            self.lock.lock(); let current = gen == self.generation; self.lock.unlock()
            if current { onFire() }
        }
        item = w
        queue.asyncAfter(deadline: .now() + interval, execute: w)
    }
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        generation += 1     // invalidate any already-dequeued item
        item?.cancel(); item = nil
    }
}

final class DataBox: @unchecked Sendable {
    private let lock = NSLock(); private var d = Data()
    func set(_ x: Data) { lock.lock(); d = x; lock.unlock() }
    var value: Data { lock.lock(); defer { lock.unlock() }; return d }
    var string: String { String(decoding: value, as: UTF8.self) }
}
final class FlagBox: @unchecked Sendable {
    private let lock = NSLock(); private var v = false
    func set() { lock.lock(); v = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return v }
}
final class CounterBox: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0
    @discardableResult func add(_ x: Int) -> Int { lock.lock(); defer { lock.unlock() }; n += x; return n }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}
/// Holds the subprocess state shared across drain/wait/watchdog queues.
/// @unchecked Sendable invariant (Codex audit #6): only thread-safe `Process` operations cross
/// threads — `run()` (once, before any queue work), `isRunning`/`terminate()`/`waitUntilExit()`/
/// `terminationStatus` (documented safe to call concurrently) — and the captured buffers/flag are
/// lock-guarded (`DataBox`/`FlagBox`). The `Pipe` file handles are each drained by exactly one queue.
/// Follow-up: migrate to apple/swift-subprocess for compiler-checked confinement.
final class ProcHolder: @unchecked Sendable {
    let process = Process()
    let out = Pipe(); let err = Pipe(); let inp = Pipe()
    let outBuf = DataBox(); let errBuf = DataBox(); let timedOut = FlagBox()

    // Serialize process lifecycle (SME C1): the watchdog and Task-cancellation `onCancel` can both try to
    // stop the child from different threads. Without this, a check-then-act on `isRunning` races, and
    // `terminate()` on a never-launched Process raises an uncatchable ObjC exception.
    private let lifecycle = NSLock()
    private var launched = false
    private var pendingTerminate = false   // a cancel that raced launch, applied once launched
    private var pendingKill = false
    func markLaunched() {
        lifecycle.lock(); defer { lifecycle.unlock() }
        launched = true
        // Apply a termination/kill that arrived in the tiny window AFTER run() but BEFORE this call
        // — otherwise the Stop button's request was silently dropped and the child ran to completion,
        // leaking a full quota call (audit C MED).
        if (pendingTerminate || pendingKill), process.isRunning { process.terminate() }
        if pendingKill, process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
    func terminateIfRunning() {
        lifecycle.lock(); defer { lifecycle.unlock() }
        guard launched else { pendingTerminate = true; return }   // record intent; markLaunched applies it
        guard process.isRunning else { return }
        process.terminate()
    }
    func killIfRunning() {
        lifecycle.lock(); defer { lifecycle.unlock() }
        guard launched else { pendingKill = true; return }
        guard process.isRunning else { return }
        kill(process.processIdentifier, SIGKILL)
    }
}
