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

/// A text-generation provider over the user's CLI subscription (claude / codex / a router over both).
/// The abstraction lets `AskEngine`/`AIImporter` flip providers and fall back transparently (Phase 5).
public protocol LLMProvider: Sendable {
    nonisolated var id: ProviderID { get }
    func complete(prompt: String, system: String?, model: String, timeout: TimeInterval) async throws -> Completion
    func completeJSON(prompt: String, system: String?, schema: String, model: String, timeout: TimeInterval) async throws -> String
}

public extension LLMProvider {
    func complete(prompt: String, system: String? = nil) async throws -> Completion {
        try await complete(prompt: prompt, system: system, model: "sonnet", timeout: 120)
    }
    func completeJSON(prompt: String, system: String?, schema: String) async throws -> String {
        try await completeJSON(prompt: prompt, system: system, schema: schema, model: "sonnet", timeout: 180)
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

    /// Run `executable` with `args`, optionally piping `stdin`. Removes `scrub` env vars (→ forces CLI
    /// subscription auth), sets `cwd`, drains stdout+stderr concurrently (no pipe-buffer deadlock),
    /// and kills the child after `timeout`.
    static func run(executable: String, args: [String], stdin: String? = nil, cwd: String? = nil,
                    scrub: [String] = [], extraEnv: [String: String] = [:],
                    timeout: TimeInterval = 120) async throws -> Output {
        let h = ProcHolder()
        h.process.executableURL = URL(fileURLWithPath: executable)
        h.process.arguments = args
        if let cwd { h.process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        var env = ProcessInfo.processInfo.environment
        for k in scrub { env.removeValue(forKey: k) }
        for (k, v) in extraEnv { env[k] = v }
        h.process.environment = env
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
            h.terminateIfRunning()   // Stop button → kill the child; lock-guarded + launch-aware (SME C1)
        }
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
    func markLaunched() { lifecycle.lock(); launched = true; lifecycle.unlock() }
    func terminateIfRunning() {
        lifecycle.lock(); defer { lifecycle.unlock() }
        guard launched, process.isRunning else { return }
        process.terminate()
    }
    func killIfRunning() {
        lifecycle.lock(); defer { lifecycle.unlock() }
        guard launched, process.isRunning else { return }
        kill(process.processIdentifier, SIGKILL)
    }
}
