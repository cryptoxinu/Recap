import SwiftUI
import CallBrainCore
import CallBrainAppCore

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
    /// The stop-on-leave sub-toggle (W1d) — default OFF, only relevant when auto-record is on.
    static let autoStopKey = "callbrain.autoStopOnLeave"

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

    /// When to stop suppressing a handled occurrence. Past the event end by the SAME grace window
    /// `eventHappeningNow` uses, so a call that runs — or resumes after an auto-stop — a few minutes past
    /// its scheduled end can neither be re-armed by the schedule timer nor re-started by start-on-join.
    /// (W1d review: the old `event.end` bound left an `end … end+grace` window where a resumed call
    /// double-started a second recording of the same meeting.)
    private static func suppressUntil(_ end: Date?, now: Date = Date()) -> Date {
        max(end ?? now, now).addingTimeInterval(graceMinutes * 60)
    }

    // MARK: - W1d — start-on-join / guarded stop-on-leave (the live "conference active" signal)

    /// Polls the conference-active signal + recording state, feeds `decideAutoRecord`, and acts.
    private var activeSignalTimer: Task<Void, Never>?
    /// Has the conference been active at least once during the CURRENT recording? Latched so a
    /// scheduled recording whose captions never flowed (non-Meet / captions-off call) is never
    /// mistaken for "the caller left" and auto-stopped. Reset whenever no recording is running.
    private var sawConferenceActive = false
    /// How often to sample the live signal. Modest — this is not the hot path.
    private static let pollSeconds: Double = 5
    /// A live conference for START = a caption arrived within this (tight) window, so only a truly
    /// live call triggers a start (not a call that ended a minute ago, or a stale background tab).
    private static let startActiveWindow: Double = 25
    /// A conference is treated as LEFT for STOP only after this (generous) caption silence, so a
    /// normal talk gap / brief tab flap can't cut a call short. Much longer than `startActiveWindow`.
    private static let stopInactiveWindow: Double = 90
    /// Stop-on-leave floor handed to the decider (matches its own 20s default).
    private static let minAutoStopSeconds: Double = 20

    init() { isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey) }

    func setEnabled(_ on: Bool, env: AppEnvironment) {
        isEnabled = on
        reschedule(env: env)
    }

    /// Cancel the pending timer and arm the next eligible meeting (or nothing). Idempotent — every
    /// trigger (launch, calendar change, link change, post-record) cancels the prior timer first.
    func reschedule(env: AppEnvironment) {
        syncActiveSignalObserver(env: env)   // start/stop the join/leave observer to match `isEnabled`
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
        handledUntil[eventID] = Self.suppressUntil(event?.end, now: now)

        let stillValid = event != nil
            && ConferenceLink.detect(in: event!) != nil
            && hub.links[eventID] == nil
            && env.recording.phase == .idle
        if stillValid, let event {
            await env.recording.startAuto(env: env, title: event.title, eventID: eventID)
            // A fresh recording begins "not yet seen live" — reset the latch on EVERY auto-start so a
            // back-to-back recording (A auto-stops, B auto-starts within one poll cycle) can't inherit
            // A's stale "went-live" state and get wrongly auto-stopped ~20s in. (W1d review, HIGH.)
            sawConferenceActive = false
        }
        armedEventID = nil
        reschedule(env: env)   // arm the meeting after this one (this occurrence now suppressed)
    }

    // MARK: - Join/leave observer (W1d)

    /// Start (or stop) the conference-active poll to match `isEnabled`. Idempotent + safe to call on
    /// every `reschedule` (launch, calendar/link change): it never spawns a second loop, and turning
    /// auto-record off cancels the loop and clears the latch.
    private func syncActiveSignalObserver(env: AppEnvironment) {
        guard isEnabled else {
            activeSignalTimer?.cancel(); activeSignalTimer = nil
            sawConferenceActive = false
            return
        }
        guard activeSignalTimer == nil else { return }   // already observing
        activeSignalTimer = Task { [weak self, weak env] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.pollSeconds))
                guard !Task.isCancelled, let self, let env, self.isEnabled else { return }
                await self.evaluateActiveSignal(env: env)
            }
        }
    }

    /// One sample: read the live signals, ask the pure decider, act. Runs on the main actor (it drives
    /// the recording model + reads the calendar hub) but does no heavy work — just a freshness read and
    /// a start/stop hop.
    private func evaluateActiveSignal(env: AppEnvironment) async {
        let rec = env.recording
        let recordingActive = rec.phase == .recording

        // Contextual freshness window: TIGHT for start (only a truly-live call), GENEROUS for stop
        // (only after a long caption silence, so a talk gap / tab flap can't cut a call short).
        let window = recordingActive ? Self.stopInactiveWindow : Self.startActiveWindow
        let conferenceActive = (env.meetSession.secondsSinceLastTurn().map { $0 <= window }) ?? false

        // Latch "we actually joined this call": only auto-stop a recording we saw go live, never a
        // scheduled non-Meet / captions-off recording whose caption stream never flowed.
        if !recordingActive { sawConferenceActive = false }
        else if conferenceActive { sawConferenceActive = true }

        // The scheduled call being joined (5-min grace each side handles a LATE join), with a real
        // conference link and not already linked to a call. nil ⇒ start-on-join won't fire.
        let target = recordingActive ? nil : startTarget(env: env)

        let action = decideAutoRecord(AutoRecordInputs(
            autoRecordEnabled: isEnabled,
            autoStopEnabled: UserDefaults.standard.bool(forKey: Self.autoStopKey),
            armedEventID: target?.id,
            conferenceActive: conferenceActive,
            conferenceWasActive: sawConferenceActive,
            recordingActive: recordingActive,
            recordingWasAutoStarted: rec.wasAutoStarted,
            recordingElapsedSeconds: rec.elapsed,
            minAutoStopSeconds: Self.minAutoStopSeconds))

        switch action {
        case .none:
            break
        case .start:
            // Start-on-join is SCHEDULED-only: require a resolved target (re-checking phase, since a
            // manual/extension start could have raced in since the read). Never records a background
            // tab that has no calendar entry.
            guard rec.phase == .idle, let target else { return }
            await rec.startAuto(env: env, title: target.title, eventID: target.id)
            if rec.phase == .recording {
                sawConferenceActive = false   // fresh recording begins "not yet seen live" (see fire()).
                // This occurrence is now handled — the schedule-time timer must not fire it too.
                handledUntil[target.id] = Self.suppressUntil(target.end)
            }
        case .stop:
            guard rec.phase == .recording else { return }
            let stoppedEventID = rec.linkedEventID
            await rec.stop(env: env)
            // Suppress an immediate re-start of the SAME call: if captions resume after we auto-stop
            // (e.g. a long mid-call silence), don't spawn a second recording of one meeting.
            if let stoppedEventID {
                let end = env.calendarHub.upcoming(limit: 50).first { $0.id == stoppedEventID }?.end
                handledUntil[stoppedEventID] = Self.suppressUntil(end)
            }
            reschedule(env: env)   // arm the meeting after this one
        }
    }

    /// The scheduled event happening RIGHT NOW that we'd link a start-on-join recording to: has a
    /// conference link, isn't already linked to a call, and isn't a just-handled occurrence. The
    /// hub's `eventHappeningNow` grace (±5 min) means a call joined late still resolves here.
    private func startTarget(env: AppEnvironment) -> CalendarEvent? {
        let hub = env.calendarHub
        let now = Date()
        guard let ev = hub.eventHappeningNow(),
              ConferenceLink.detect(in: ev) != nil,
              hub.links[ev.id] == nil,
              (handledUntil[ev.id].map { now < $0 } != true)
        else { return nil }
        return ev
    }
}
