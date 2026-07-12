import Testing
import Foundation
@testable import CallBrainAppCore

/// Perfection plan Task 5.1b (enabler E4, v1) — ONE scheduler for background work instead of a
/// fifth bespoke queue (judge MAJOR). Minimal by design: budgeted concurrency, user-ask priority,
/// failure isolation. Phase 8.1 adopts this for ALL background jobs.
@Suite("JobScheduler")
struct JobSchedulerTests {

    @Test("respects the concurrency budget")
    func testSerializesJobsWithinBudget() async throws {
        let scheduler = JobScheduler(budget: 2)
        let gauge = Gauge()
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<6 {
                group.addTask {
                    await scheduler.run(label: "job\(i)", priority: .background) {
                        let now = await gauge.enter()
                        #expect(now <= 2)                       // never more than budget at once
                        try? await Task.sleep(for: .milliseconds(40))
                        await gauge.exit()
                    }
                }
            }
        }
        #expect(await gauge.peak <= 2)
        #expect(await gauge.total == 6)                          // all jobs ran
    }

    @Test("a user-priority job runs even when background jobs saturate the budget")
    func testUserPriorityJumpsQueue() async throws {
        let scheduler = JobScheduler(budget: 1)
        let order = Order()
        let gate = ReleaseGate()
        // Saturate with a slow background job, then queue another background + one user job.
        async let a: Void = scheduler.run(label: "bg1", priority: .background) {
            await gate.wait()
            await order.mark("bg1")
        }
        try await Task.sleep(for: .milliseconds(60))            // bg1 occupies the slot
        async let b: Void = scheduler.run(label: "bg2", priority: .background) { await order.mark("bg2") }
        try await Task.sleep(for: .milliseconds(60))
        async let u: Void = scheduler.run(label: "user", priority: .user) { await order.mark("user") }
        try await Task.sleep(for: .milliseconds(120))           // let both waiters enqueue under load
        await gate.release()
        _ = await (a, b, u)
        let seq = await order.seq
        #expect(seq.first == "bg1")
        #expect(seq.firstIndex(of: "user")! < seq.firstIndex(of: "bg2")!)   // user jumps bg2
    }

    @Test("a throwing job is isolated — the queue keeps draining")
    func testJobSurvivesFailureIsolated() async throws {
        let scheduler = JobScheduler(budget: 1)
        let order = Order()
        await scheduler.run(label: "boom", priority: .background) { throw TestError.boom }
        await scheduler.run(label: "after", priority: .background) { await order.mark("after") }
        #expect(await order.seq == ["after"])
    }

    enum TestError: Error { case boom }
    actor Gauge {
        var current = 0; var peak = 0; var total = 0
        func enter() -> Int { current += 1; peak = max(peak, current); total += 1; return current }
        func exit() { current -= 1 }
    }
    actor Order {
        var seq: [String] = []
        func mark(_ s: String) { seq.append(s) }
    }

    actor ReleaseGate {
        private var open = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if open { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func release() {
            open = true
            let pending = waiters
            waiters = []
            for waiter in pending { waiter.resume() }
        }
    }
}
