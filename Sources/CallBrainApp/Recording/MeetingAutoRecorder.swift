import SwiftUI
import CallBrainCore

/// Opt-in auto-record (Granola-style): when a calendar meeting that has a video-conference link is
/// about to start, begin a pre-linked recording automatically so the founder never forgets to hit
/// record. DEFAULT OFF — silent capture is a deliberate choice, not a surprise; and it only ever
/// targets meetings with a real conference link (never a solo focus block). Only one meeting is
/// armed at a time (the soonest eligible), re-armed whenever the calendar or its links change or a
/// recording finishes. Once an occurrence has been HANDLED (recorded, or skipped because a
/// recording was already running) it is suppressed until its end time, so the fire-time re-arm can
/// never spin on the same delay==0 event or double-start a call whose link hasn't landed yet.
@MainActor
@Observable
final class MeetingAutoRecorder {
    static let enabledKey = "callbrain.autoRecordEnabled"

    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
        }
    }
    /// The event we're currently waiting to record (for a subtle "will auto-record" hint in the UI).
    private(set) var armedEventID: String?
    private var timer: Task<Void, Never>?
    /// Occurrences already handled → suppressed until their end time (prevents same-event re-arm
    /// loops and a double auto-start before the recording→meeting link lands).
    private var handledUntil: [String: Date] = [:]

    /// If the app launches (or the calendar loads) mid-meeting, still auto-start within this grace
    /// window rather than missing an already-running call.
    private static let graceMinutes: Double = 5

    init() { isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey) }

    func setEnabled(_ on: Bool, env: AppEnvironment) {
        isEnabled = on
        reschedule(env: env)
    }

    /// Cancel the pending timer and arm the next eligible meeting (or nothing). Idempotent — every
    /// trigger (launch, calendar change, link change, post-record) cancels the prior timer first.
    func reschedule(env: AppEnvironment) {
        timer?.cancel(); timer = nil; armedEventID = nil
        guard isEnabled else { return }
        let now = Date()
        handledUntil = handledUntil.filter { $0.value > now }   // prune expired suppressions
        guard let next = nextEligible(env: env, now: now) else { return }

        armedEventID = next.id
        let delay = max(0, next.start.timeIntervalSinceNow)
        let eventID = next.id
        timer = Task { [weak self, weak env] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled, let self, let env, self.isEnabled else { return }
            await self.fire(env: env, eventID: eventID)
        }
    }

    /// The soonest meeting with a conference link that isn't already linked to a call and hasn't
    /// been handled this occurrence. Reads `hub.links` (kept fresh by `refreshLinks`) for the arm
    /// decision; the fire path re-verifies against a fresh snapshot.
    private func nextEligible(env: AppEnvironment, now: Date) -> CalendarEvent? {
        let hub = env.calendarHub
        return hub.upcoming(limit: 20)
            .filter { e in
                ConferenceLink.detect(in: e) != nil
                    && hub.links[e.id] == nil
                    && (handledUntil[e.id].map { now < $0 } != true)
            }
            .filter { $0.start > now.addingTimeInterval(-Self.graceMinutes * 60) }
            .min { $0.start < $1.start }
    }

    /// Fire time: re-resolve the event from a FRESH calendar + link snapshot before starting, so a
    /// deleted / moved / ended / link-removed / already-recorded meeting never auto-starts on its
    /// old schedule (P3 audit HIGH). Every outcome marks the occurrence handled so we don't re-arm
    /// it, then arms the meeting after this one.
    private func fire(env: AppEnvironment, eventID: String) async {
        let hub = env.calendarHub
        await hub.refreshLinks()   // fresh link state (background linker / reconciler may have run)
        let now = Date()
        let event = hub.upcoming(limit: 50).first { $0.id == eventID }
        // Suppress this occurrence regardless of outcome (found→its end; gone→a bounded window).
        handledUntil[eventID] = event?.end ?? now.addingTimeInterval(3600)

        let stillValid = event != nil
            && ConferenceLink.detect(in: event!) != nil
            && hub.links[eventID] == nil
            && env.recording.phase == .idle
        if stillValid, let event {
            await env.recording.startAuto(env: env, title: event.title, eventID: eventID)
        }
        armedEventID = nil
        reschedule(env: env)   // arm the meeting after this one (this occurrence now suppressed)
    }
}
