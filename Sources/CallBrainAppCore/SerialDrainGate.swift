import Foundation

/// Enabler E2 (Task 8.1) — THE serial-drain state machine, extracted from ImportCoordinator
/// (and adopted by SummaryScheduler) so its trickiest property is TESTED instead of re-derived
/// per queue: a job enqueued in the instant between the drain's last empty read and
/// `processing = false` must never be stranded until the next enqueue (the lost-wakeup race —
/// audit HIGH in Phase 2).
///
/// Usage (single-threaded owner, e.g. a @MainActor coordinator):
///   if gate.requestDrain() { repeat { await drainOnce() } while gate.shouldLoop(); gate.finish() }
public struct SerialDrainGate: Sendable {
    public private(set) var processing = false
    private var drainRequested = false

    public init() {}

    /// Ask to drain. Returns true when the CALLER should run the drain loop; false when a drain
    /// is already running (the running loop is flagged to re-check before it exits).
    public mutating func requestDrain() -> Bool {
        if processing { drainRequested = true; return false }
        processing = true
        return true
    }

    /// After one drain pass: loop again? (True exactly when someone requested mid-drain.)
    public mutating func shouldLoop() -> Bool {
        let again = drainRequested
        drainRequested = false
        return again
    }

    /// The drain loop exited.
    public mutating func finish() { processing = false }
}
