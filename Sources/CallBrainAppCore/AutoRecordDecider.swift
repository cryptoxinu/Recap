import Foundation

/// W1d — Fathom-style auto-record decision logic, extracted as a PURE value function so every rule
/// is unit-testable with no I/O, no timers, no WhisperKit, and no `AppEnvironment`. The
/// `MeetingAutoRecorder` (app target) samples the live signals, feeds them in here, and acts on the
/// returned `AutoRecordAction`. Keeping the policy here means the flap-guard / manual-recording /
/// never-joined edge cases are asserted directly in `AutoRecordDeciderTests` instead of behind a
/// live meeting.
///
/// Both toggles this reads default OFF (Fathom stays primary): auto-record is opt-in, and
/// stop-on-leave is a second opt-in under it. When `autoRecordEnabled == false` the answer is always
/// `.none` — the feature simply doesn't exist for anyone who hasn't turned it on.
public enum AutoRecordAction: Equatable, Sendable {
    /// Do nothing this tick.
    case none
    /// Start a recording now, linking it to `eventID` when a scheduled call is being joined.
    case start(eventID: String?)
    /// Stop the current recording — only ever reached for an auto-started recording (see the rules).
    case stop
}

/// A snapshot of everything the auto-record policy needs. A value type so a caller can build it off
/// the live app state and hand it to `decideAutoRecord` without the decision touching any live object.
public struct AutoRecordInputs: Equatable, Sendable {
    /// Master switch (`callbrain.autoRecordEnabled`, default OFF). OFF ⇒ never auto-anything.
    public var autoRecordEnabled: Bool
    /// The stop-on-leave sub-toggle (`callbrain.autoStopOnLeave`, default OFF). Only gates `.stop`.
    public var autoStopEnabled: Bool
    /// The scheduled event this join is being attributed to (so the recording links to the call).
    /// `nil` means no scheduled call matched "happening now" — start-on-join is scheduled-only, so a
    /// `nil` here is a signal to the orchestrator not to auto-start an unscheduled/background tab.
    public var armedEventID: String?
    /// Is a conference live RIGHT NOW? Primary signal: Google Meet captions arrived recently
    /// (`MeetSession.secondsSinceLastTurn` within the orchestrator's freshness window).
    public var conferenceActive: Bool
    /// Has the conference been active at least once DURING the current recording? Guards the
    /// "never joined" case: a scheduled recording of a non-Meet / captions-off call whose caption
    /// stream never flowed must NOT be auto-stopped just because `conferenceActive` reads false.
    public var conferenceWasActive: Bool
    /// Is a recording running right now? (phase == .recording)
    public var recordingActive: Bool
    /// Was the CURRENT recording started by auto-record (vs. the founder pressing record)? A manual
    /// recording is the founder's to stop — never auto-stopped.
    public var recordingWasAutoStarted: Bool
    /// How long the current recording has been running (seconds).
    public var recordingElapsedSeconds: Double
    /// Floor before stop-on-leave may fire, so a transient tab flap right after a join can't kill a
    /// just-started call. Default 20s.
    public var minAutoStopSeconds: Double

    public init(autoRecordEnabled: Bool,
                autoStopEnabled: Bool,
                armedEventID: String? = nil,
                conferenceActive: Bool,
                conferenceWasActive: Bool = false,
                recordingActive: Bool,
                recordingWasAutoStarted: Bool = false,
                recordingElapsedSeconds: Double = 0,
                minAutoStopSeconds: Double = 20) {
        self.autoRecordEnabled = autoRecordEnabled
        self.autoStopEnabled = autoStopEnabled
        self.armedEventID = armedEventID
        self.conferenceActive = conferenceActive
        self.conferenceWasActive = conferenceWasActive
        self.recordingActive = recordingActive
        self.recordingWasAutoStarted = recordingWasAutoStarted
        self.recordingElapsedSeconds = recordingElapsedSeconds
        self.minAutoStopSeconds = minAutoStopSeconds
    }
}

/// The one decision. Pure: same inputs ⇒ same action, always.
///
/// Precedence:
///  1. Master switch OFF ⇒ `.none` (nothing else is even considered).
///  2. A recording is running ⇒ consider GUARDED stop-on-leave; if any guard fails, `.none`.
///  3. Nothing recording ⇒ consider START-on-join; fires on a live conference regardless of the
///     clock (which is exactly what lets a call that started LATE still record).
public func decideAutoRecord(_ i: AutoRecordInputs) -> AutoRecordAction {
    // (1) Master switch. Both this and stop-on-leave default OFF, so an untouched install is inert.
    guard i.autoRecordEnabled else { return .none }

    // (2) Guarded stop-on-leave. Every clause must hold or the recording keeps running.
    if i.recordingActive {
        guard i.autoStopEnabled,                              // opt-in sub-toggle (default OFF)
              i.recordingWasAutoStarted,                      // NEVER stop a manual recording
              i.conferenceWasActive,                          // only "left" a call we actually joined
              !i.conferenceActive,                            // the call is no longer live
              i.recordingElapsedSeconds >= i.minAutoStopSeconds  // flap guard (≥20s)
        else { return .none }
        return .stop
    }

    // (3) Start-on-join. The trigger is the live conference signal, not the schedule — a late call
    // still records. `armedEventID` carries the scheduled call to link (may be nil; the orchestrator
    // treats a nil link as "no scheduled call to attach", so it won't record a background tab).
    if i.conferenceActive {
        return .start(eventID: i.armedEventID)
    }
    return .none
}
