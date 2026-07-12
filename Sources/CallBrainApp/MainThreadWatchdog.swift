import Foundation
import QuartzCore

/// Tiny lock-free flag for the watchdog's did-the-ping-land check.
final class AtomicBool: @unchecked Sendable {
    private let lock = NSLock(); private var v = true
    func load() -> Bool { lock.lock(); defer { lock.unlock() }; return v }
    func store(_ x: Bool) { lock.lock(); defer { lock.unlock() }; v = x }
}

/// Diagnostic main-thread freeze detector. Enabled by `CALLBRAIN_WATCHDOG=1`; off (zero cost) otherwise.
///
/// Every `interval` it pings the main thread from a background queue and logs — once per stall — if the
/// main thread took longer than `threshold` to answer, i.e. it was blocked (a beachball/pinwheel). This
/// is how we VERIFY the "no main-thread blocking" claim instead of asserting it: launch with the env var,
/// drive the app, and a clean run prints no `⚠️ main thread blocked` lines.
final class MainThreadWatchdog: @unchecked Sendable {
    static let shared = MainThreadWatchdog()

    private let queue = DispatchQueue(label: "callbrain.watchdog", qos: .utility)
    private let interval: TimeInterval = 0.5
    private let threshold: TimeInterval = 0.25
    /// The first few seconds after launch, the main thread is legitimately busy building the view hierarchy,
    /// opening the DB, and doing the FIRST data-loading render of the opened surface (a startup cost, not a
    /// beachball). We record those but tag them `[launch]` so the smoke harness can distinguish an unavoidable
    /// launch hitch from a mid-session freeze (the bug class we chase — those fire seconds/minutes into use,
    /// well past this window, like the 341ms answer-render stall did at 37s).
    private let launchGrace: TimeInterval = 3.0
    private var running = false
    private var startedAt: TimeInterval = 0
    /// Reliable sink for open-launched apps: NSLog isn't queryable via `log show` when launched by Launch
    /// Services, so stalls are ALSO appended to this file, which the smoke harness reads authoritatively.
    private let logPath = "/tmp/cb-watchdog.log"

    private let pingLanded = AtomicBool()
    private var sampled = false

    /// Sample OUR OWN process while the main thread is provably blocked — the resulting file's
    /// main-thread stack is the stall culprit, no guessing.
    private func captureStallSample() {
        guard !sampled else { return }
        sampled = true
        let out = "/tmp/cb-stall-\(ProcessInfo.processInfo.processIdentifier).txt"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        p.arguments = ["\(ProcessInfo.processInfo.processIdentifier)", "2", "-file", out]
        try? p.run()
        append("stall sample → \(out)")
    }

    func startIfEnabled() {
        guard ProcessInfo.processInfo.environment["CALLBRAIN_WATCHDOG"] == "1", !running else { return }
        running = true
        startedAt = CACurrentMediaTime()
        NSLog("🐕 Recap main-thread watchdog ON (warns if main thread blocks > %dms)", Int(threshold * 1000))
        tick()
    }

    private func tick() {
        let sent = CACurrentMediaTime()
        // Stall-stack capture (diagnosis mode): if the ping hasn't landed after the threshold,
        // the main thread is blocked RIGHT NOW — sample ourselves so the log names the culprit
        // stack instead of just the duration. One capture per run (they're expensive).
        if ProcessInfo.processInfo.environment["CALLBRAIN_WATCHDOG_SAMPLE"] == "1" {
            queue.asyncAfter(deadline: .now() + threshold + 0.05) { [weak self] in
                guard let self, !self.pingLanded.load() else { return }
                self.captureStallSample()
            }
        }
        pingLanded.store(false)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pingLanded.store(true)
            let blockedMs = (CACurrentMediaTime() - sent) * 1000
            if blockedMs > self.threshold * 1000 {
                let sinceStart = CACurrentMediaTime() - self.startedAt
                let tag = sinceStart < self.launchGrace ? "launch" : "session"
                NSLog("🐕⚠️ main thread blocked %.0f ms [%@]", blockedMs, tag)
                self.append("blocked \(Int(blockedMs))ms [\(tag)] at \(String(format: "%.1f", sinceStart))s")
            }
            self.queue.asyncAfter(deadline: .now() + self.interval) { [weak self] in self?.tick() }
        }
    }

    private func append(_ line: String) {
        let url = URL(fileURLWithPath: logPath)
        guard let data = (line + "\n").data(using: .utf8) else { return }
        if let fh = try? FileHandle(forWritingTo: url) { defer { try? fh.close() }; fh.seekToEndOfFile(); fh.write(data) }
        else { try? data.write(to: url) }
    }
}
