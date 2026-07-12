import Foundation
import os

/// Perfection plan Task 5.1b (enabler E4, v1) — the ONE background-work scheduler. The app had
/// four bespoke queues (imports, summaries, reminders, Drive sync) and each shipped its own race
/// class; new background work (embedding backfill now; speaker naming, digest, linker review in
/// Phase 8) runs HERE. Deliberately minimal: a concurrency budget shared by all jobs, two
/// priorities (user beats background), FIFO within a priority, failure isolation, os.Logger
/// diagnostics. Not persistent — durable state (e.g. pending_embeddings) lives in the Store and
/// jobs re-derive their work, so a crash loses nothing.
public actor JobScheduler {
    public enum Priority: Sendable { case user, background }

    private let budget: Int
    private var running = 0
    private var userQueue: [CheckedContinuation<Void, Never>] = []
    private var backgroundQueue: [CheckedContinuation<Void, Never>] = []
    private static let log = Logger(subsystem: "com.callbrain", category: "jobs")

    public init(budget: Int = 2) { self.budget = max(1, budget) }

    /// Run `work` when a slot frees up. Errors are logged and swallowed — one bad job must never
    /// take down the queue (callers that care use their own durable state to retry).
    public func run(label: String, priority: Priority, work: @Sendable @escaping () async throws -> Void) async {
        await acquire(priority)
        Self.log.debug("job start: \(label, privacy: .public)")
        do { try await work() }
        catch { Self.log.error("job failed: \(label, privacy: .public) — \(error.localizedDescription)") }
        release()
    }

    private func acquire(_ priority: Priority) async {
        if running < budget { running += 1; return }
        // The slot is TRANSFERRED by release() — a resumed waiter already owns it and must not
        // re-increment (integration-audit HIGH: increment-after-resume let a fresh acquire slip
        // into the freed slot first, running the pool over budget).
        await withCheckedContinuation { cont in
            switch priority {
            case .user: userQueue.append(cont)
            case .background: backgroundQueue.append(cont)
            }
        }
    }

    private func release() {
        // Hand the slot straight to a waiter (running count unchanged); only decrement when
        // nobody is waiting.
        if !userQueue.isEmpty { userQueue.removeFirst().resume() }         // user beats background
        else if !backgroundQueue.isEmpty {
            let next = backgroundQueue.removeFirst()
            Task { await resumeBackgroundAfterPriorityTurn(next) }
        }
        else { running -= 1 }
    }

    private func resumeBackgroundAfterPriorityTurn(_ next: CheckedContinuation<Void, Never>) async {
        await Task.yield()
        if !userQueue.isEmpty {
            backgroundQueue.insert(next, at: 0)
            userQueue.removeFirst().resume()
        } else {
            next.resume()
        }
    }
}
