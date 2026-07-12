import Foundation
import os

/// Per-stage latency for one ask (perfection plan Task 0.3, critic #8). Every later phase's
/// "faster" claim is proven against these numbers, never vibes. Phase 3 adds `spawnMS` +
/// `firstTokenMS` when streaming lands (fields are optional so old log lines keep decoding).
public struct AskMetrics: Codable, Equatable, Sendable {
    public var retrieveMS: Int
    public var promptBuildMS: Int
    public var generateMS: Int
    public var totalMS: Int
    public var provider: String?
    public var model: String?
    public var evidenceCount: Int
    public var spawnMS: Int?
    public var firstTokenMS: Int?

    public init(retrieveMS: Int, promptBuildMS: Int, generateMS: Int, totalMS: Int,
                provider: String?, model: String?, evidenceCount: Int,
                spawnMS: Int? = nil, firstTokenMS: Int? = nil) {
        self.retrieveMS = retrieveMS; self.promptBuildMS = promptBuildMS
        self.generateMS = generateMS; self.totalMS = totalMS
        self.provider = provider; self.model = model; self.evidenceCount = evidenceCount
        self.spawnMS = spawnMS; self.firstTokenMS = firstTokenMS
    }

    static let log = Logger(subsystem: "com.callbrain", category: "ask-metrics")

    /// Default diagnostics location, sibling to the store.
    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CallBrain/diagnostics", isDirectory: true)
    }

    /// Append one JSON line to `ask-metrics.jsonl`. Telemetry must never break an answer:
    /// failures are swallowed to os.Logger only. Uses O_APPEND — the kernel positions every
    /// write at EOF atomically, so concurrent asks (and even a concurrent cbeval process) can't
    /// interleave a seek/write race or clobber the file on first create (Codex phase-0 MED 2).
    public func appendToLog(directory: URL = AskMetrics.defaultDirectory) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("ask-metrics.jsonl")
            var line = try JSONEncoder().encode(self)
            line.append(0x0A)
            let fd = open(file.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
            guard fd >= 0 else {
                Self.log.error("metrics open failed: errno \(errno)")
                return
            }
            defer { close(fd) }
            let wrote = line.withUnsafeBytes { buf in write(fd, buf.baseAddress, buf.count) }
            if wrote != line.count { Self.log.error("metrics short write: \(wrote)/\(line.count)") }
        } catch {
            Self.log.error("metrics append failed: \(error.localizedDescription)")
        }
    }
}

/// Millisecond stopwatch over ContinuousClock — small helper so AskEngine reads cleanly.
struct StageClock {
    private let clock = ContinuousClock()
    private var last: ContinuousClock.Instant
    let started: ContinuousClock.Instant
    init() { let now = ContinuousClock().now; started = now; last = now }
    /// Milliseconds since the previous lap (or init).
    mutating func lapMS() -> Int {
        let now = clock.now
        defer { last = now }
        return Int(last.duration(to: now).components.seconds * 1000)
            + Int(last.duration(to: now).components.attoseconds / 1_000_000_000_000_000)
    }
    /// Milliseconds since init.
    func totalMS() -> Int {
        let d = started.duration(to: clock.now)
        return Int(d.components.seconds * 1000) + Int(d.components.attoseconds / 1_000_000_000_000_000)
    }
}
