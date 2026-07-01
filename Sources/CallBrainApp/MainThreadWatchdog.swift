import Foundation
import QuartzCore

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
    private var running = false

    func startIfEnabled() {
        guard ProcessInfo.processInfo.environment["CALLBRAIN_WATCHDOG"] == "1", !running else { return }
        running = true
        NSLog("🐕 CallBrain main-thread watchdog ON (warns if main thread blocks > %dms)", Int(threshold * 1000))
        tick()
    }

    private func tick() {
        let sent = CACurrentMediaTime()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let blockedMs = (CACurrentMediaTime() - sent) * 1000
            if blockedMs > self.threshold * 1000 {
                NSLog("🐕⚠️ main thread blocked %.0f ms", blockedMs)
            }
            self.queue.asyncAfter(deadline: .now() + self.interval) { [weak self] in self?.tick() }
        }
    }
}
