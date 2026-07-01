import Foundation
import CallBrainCore

/// Owns the lifecycle of the local summary model so it's well-behaved on a laptop: **one summary at a
/// time** (a 14B model thrashing in parallel would spike memory + battery), user-initiated jobs jump the
/// queue and always run, automatic (import/backfill) jobs **pause** on Low Power Mode or critical thermal
/// and **resume the instant power recovers** (no relaunch needed), and every candidate model is **evicted
/// from memory the moment the queue drains** so nothing stays pinned drawing power.
///
/// This is the single funnel for every summary pass — nothing calls `generateCallSummary` directly except
/// here, which guarantees the serialization + power discipline can't be bypassed. All state is
/// `@MainActor`-isolated; the only suspension points are the `generate`/`unload` awaits, so two summaries
/// can never run at once.
@MainActor
@Observable
final class SummaryScheduler {
    private unowned let env: AppEnvironment

    /// The meeting currently being summarized (drives per-call spinners). nil when idle.
    private(set) var workingOn: String?

    /// Meeting IDs whose most recent summary attempt FAILED (Ollama down AND no CLI subscription). Surfaced
    /// in MeetingDetailView so a failed "Generate" shows an honest error instead of the neutral "No summary
    /// yet" placeholder. Cleared the moment the same call is re-queued or a pass succeeds.
    private(set) var lastFailed: Set<String> = []

    private var auto: [String] = []                      // battery-gated FIFO (import/backfill)
    private var queuedAuto = Set<String>()               // dedupe set for `auto` (kept intact across a pause)
    private var priority: [(id: String, cloud: Bool)] = []   // user-initiated — always runs
    private var pumping = false
    // Written only in init (on the main actor), read only in deinit (when no other access is possible).
    @ObservationIgnored nonisolated(unsafe) private var powerObservers: [NSObjectProtocol] = []

    init(env: AppEnvironment) {
        self.env = env
        // Resume paused auto work the moment the user leaves Low Power Mode or the Mac cools down — without
        // this the only recovery would be a relaunch (the "half-assed on/off" we're avoiding).
        let nc = NotificationCenter.default
        for name in [ProcessInfo.thermalStateDidChangeNotification, .NSProcessInfoPowerStateDidChange] {
            powerObservers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onPowerChange() }
            })
        }
    }

    deinit { powerObservers.forEach { NotificationCenter.default.removeObserver($0) } }

    // MARK: - public API

    /// Queue an automatic local summary (skipped if already queued or in flight). Battery-gated.
    func enqueueAuto(_ meetingID: String) {
        guard !queuedAuto.contains(meetingID), workingOn != meetingID else { return }
        lastFailed.remove(meetingID)   // re-queued → clear any stale failure so the UI shows "queued", not error
        queuedAuto.insert(meetingID)
        auto.append(meetingID)
        pump()
    }

    /// Queue every call that has no summary yet (launch backfill). Battery-gated; cheap when all present.
    /// Includes Gemini calls now — every call gets a concise digest (founder ask 2026-06-30).
    func backfillMissing(_ meetings: [Store.MeetingRow]) {
        for m in meetings where (m.callSummary?.isEmpty ?? true) { enqueueAuto(m.id) }
    }

    /// User pressed "Generate" / "Regenerate with AI" — runs regardless of power, ahead of the auto queue.
    /// Deduped: a meeting already in flight or pending as priority is ignored (no double 14B passes), and a
    /// pending *auto* entry for the same meeting is superseded so it isn't summarized twice.
    func requestNow(_ meetingID: String, cloud: Bool) {
        guard workingOn != meetingID, !priority.contains(where: { $0.id == meetingID }) else { return }
        lastFailed.remove(meetingID)   // user asked again → clear stale failure so the UI shows "queued", not error
        auto.removeAll { $0 == meetingID }
        queuedAuto.remove(meetingID)
        priority.append((meetingID, cloud))
        pump()
    }

    /// True while this specific call is being summarized (spinner) or is waiting in a queue (badge).
    func isWorking(on id: String) -> Bool { workingOn == id }
    func isQueued(_ id: String) -> Bool { queuedAuto.contains(id) || priority.contains { $0.id == id } }
    /// The most recent summary attempt for this call failed (local model + CLI both unavailable).
    func summaryFailed(_ id: String) -> Bool { lastFailed.contains(id) }
    /// Auto work is waiting because the machine asked us to back off for power/heat.
    var autoPausedForPower: Bool { !auto.isEmpty && !batteryOK }

    // MARK: - drain loop

    /// Run automatic jobs only when the user isn't actively conserving power and the Mac isn't overheating.
    /// Low Power Mode = explicit user intent; critical thermal = protect the hardware. (Normal/serious
    /// thermal is fine on an M-series — we don't pause a routine background pass for warmth.)
    private var batteryOK: Bool {
        let p = ProcessInfo.processInfo
        return !p.isLowPowerModeEnabled && p.thermalState != .critical
    }

    private func onPowerChange() { if batteryOK, !auto.isEmpty { pump() } }   // power recovered → resume

    private func pump() {
        guard !pumping else { return }
        pumping = true
        Task { await drain() }
    }

    private func drain() async {
        while true {
            if !priority.isEmpty {
                let job = priority.removeFirst()
                workingOn = job.id
                let ok = await env.generateCallSummary(for: job.id, preferCloud: job.cloud)
                if ok { lastFailed.remove(job.id) } else { lastFailed.insert(job.id) }
                workingOn = nil
            } else if batteryOK, let id = auto.first {
                auto.removeFirst()
                queuedAuto.remove(id)
                workingOn = id
                if env.needsAutoSummary(id) {                 // skip if a priority pass already produced it
                    let ok = await env.generateCallSummary(for: id)
                    if ok { lastFailed.remove(id) } else { lastFailed.insert(id) }
                }
                workingOn = nil
            } else {
                break   // queue empty, or auto paused for power (auto/queuedAuto kept intact → resumes later)
            }
        }
        // Idle (or paused) → evict EVERY model we might have loaded so nothing holds unified memory / draws
        // power. `unload` is a cheap best-effort no-op when a model isn't resident, so unloading the 14B and
        // the 7B fallback both is safe — and necessary, since a low-RAM Mac runs the 7B, not the 14B.
        for model in Set([env.localSummaryModel, "qwen2.5:7b", "qwen2.5:14b"]) {
            await OllamaSummarizer.unload(model: model)   // evict any heavy model so nothing stays pinned
        }
        pumping = false
        // Catch anything enqueued during the unload awaits (priority always; auto only if power allows).
        if !priority.isEmpty || (batteryOK && !auto.isEmpty) { pump() }
    }
}
