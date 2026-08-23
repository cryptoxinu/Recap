import Foundation
import Testing
@testable import CallBrainAppCore

/// W1d — the pure auto-record policy. Each rule (master gate, start-on-join, guarded stop-on-leave,
/// flap guard, never-stop-a-manual-recording, never-stop-a-call-we-never-joined) is asserted here so
/// the behavior is locked without needing a live meeting.
@Suite("AutoRecordDecider")
struct AutoRecordDeciderTests {

    // MARK: master switch

    @Test("auto-record OFF ⇒ .none even when every start/stop condition is otherwise met")
    func disabledIsAlwaysNone() {
        // Would-be START.
        #expect(decideAutoRecord(AutoRecordInputs(
            autoRecordEnabled: false, autoStopEnabled: true, armedEventID: "e1",
            conferenceActive: true, recordingActive: false)) == .none)
        // Would-be STOP.
        #expect(decideAutoRecord(AutoRecordInputs(
            autoRecordEnabled: false, autoStopEnabled: true,
            conferenceActive: false, conferenceWasActive: true,
            recordingActive: true, recordingWasAutoStarted: true,
            recordingElapsedSeconds: 120)) == .none)
    }

    // MARK: start-on-join

    @Test("conference active + enabled + not recording ⇒ .start(armedEventID)")
    func startsOnJoin() {
        let action = decideAutoRecord(AutoRecordInputs(
            autoRecordEnabled: true, autoStopEnabled: false, armedEventID: "eventKit|abc",
            conferenceActive: true, recordingActive: false))
        #expect(action == .start(eventID: "eventKit|abc"))
    }

    @Test("a call that started LATE still records — the trigger is the live signal, not the clock")
    func lateStartStillStarts() {
        // There is no schedule/now gate in the decider: a conference that becomes active well after
        // its scheduled time is indistinguishable from an on-time one, so it still starts.
        let action = decideAutoRecord(AutoRecordInputs(
            autoRecordEnabled: true, autoStopEnabled: false, armedEventID: "eventKit|late",
            conferenceActive: true, recordingActive: false))
        #expect(action == .start(eventID: "eventKit|late"))
    }

    @Test("no live conference ⇒ .none (the schedule-time path handles no-caption calls)")
    func noStartWhenConferenceInactive() {
        #expect(decideAutoRecord(AutoRecordInputs(
            autoRecordEnabled: true, autoStopEnabled: false, armedEventID: "e1",
            conferenceActive: false, recordingActive: false)) == .none)
    }

    @Test("start passes a nil armed event through (unscheduled — orchestrator won't attach)")
    func startCarriesNilArmedEvent() {
        #expect(decideAutoRecord(AutoRecordInputs(
            autoRecordEnabled: true, autoStopEnabled: false, armedEventID: nil,
            conferenceActive: true, recordingActive: false)) == .start(eventID: nil))
    }

    @Test("never a double-start: conference active but already recording ⇒ .none")
    func noStartWhenAlreadyRecording() {
        // Recording, auto-stop OFF → not a stop candidate either → .none (keep recording).
        #expect(decideAutoRecord(AutoRecordInputs(
            autoRecordEnabled: true, autoStopEnabled: false, armedEventID: "e1",
            conferenceActive: true, conferenceWasActive: true,
            recordingActive: true, recordingWasAutoStarted: true,
            recordingElapsedSeconds: 300)) == .none)
    }

    // MARK: guarded stop-on-leave

    @Test("stop-on-leave: autoStop + auto-started + joined + now-inactive + elapsed≥20 ⇒ .stop")
    func stopsOnLeaveWhenAllGuardsPass() {
        #expect(decideAutoRecord(AutoRecordInputs(
            autoRecordEnabled: true, autoStopEnabled: true,
            conferenceActive: false, conferenceWasActive: true,
            recordingActive: true, recordingWasAutoStarted: true,
            recordingElapsedSeconds: 45)) == .stop)
    }

    @Test("stop fires exactly AT the 20s floor (>=), not one tick before")
    func stopFloorIsInclusive() {
        let base = AutoRecordInputs(
            autoRecordEnabled: true, autoStopEnabled: true,
            conferenceActive: false, conferenceWasActive: true,
            recordingActive: true, recordingWasAutoStarted: true,
            recordingElapsedSeconds: 20, minAutoStopSeconds: 20)
        #expect(decideAutoRecord(base) == .stop)                       // exactly 20 ⇒ stop
        var justUnder = base; justUnder.recordingElapsedSeconds = 19.99
        #expect(decideAutoRecord(justUnder) == .none)                  // 19.99 ⇒ hold
    }

    @Test("NEVER stops a manual recording, even with every other stop guard satisfied")
    func neverStopsAManualRecording() {
        #expect(decideAutoRecord(AutoRecordInputs(
            autoRecordEnabled: true, autoStopEnabled: true,
            conferenceActive: false, conferenceWasActive: true,
            recordingActive: true, recordingWasAutoStarted: false,   // manual
            recordingElapsedSeconds: 600)) == .none)
    }

    @Test("flap guard: an auto-started recording under 20s is never auto-stopped")
    func noStopUnderTwentySeconds() {
        #expect(decideAutoRecord(AutoRecordInputs(
            autoRecordEnabled: true, autoStopEnabled: true,
            conferenceActive: false, conferenceWasActive: true,
            recordingActive: true, recordingWasAutoStarted: true,
            recordingElapsedSeconds: 5)) == .none)
    }

    @Test("no stop while the conference is still live")
    func noStopWhileConferenceActive() {
        #expect(decideAutoRecord(AutoRecordInputs(
            autoRecordEnabled: true, autoStopEnabled: true,
            conferenceActive: true, conferenceWasActive: true,
            recordingActive: true, recordingWasAutoStarted: true,
            recordingElapsedSeconds: 300)) == .none)
    }

    @Test("never stops a call we never actually joined (captions never flowed) ⇒ .none")
    func noStopWhenNeverJoined() {
        // e.g. a scheduled non-Meet / captions-off recording: conferenceWasActive stays false, so
        // conferenceActive reading false must NOT be mistaken for "left the call".
        #expect(decideAutoRecord(AutoRecordInputs(
            autoRecordEnabled: true, autoStopEnabled: true,
            conferenceActive: false, conferenceWasActive: false,
            recordingActive: true, recordingWasAutoStarted: true,
            recordingElapsedSeconds: 300)) == .none)
    }

    @Test("stop sub-toggle OFF ⇒ never stops (only the main toggle is on)")
    func noStopWhenAutoStopDisabled() {
        #expect(decideAutoRecord(AutoRecordInputs(
            autoRecordEnabled: true, autoStopEnabled: false,
            conferenceActive: false, conferenceWasActive: true,
            recordingActive: true, recordingWasAutoStarted: true,
            recordingElapsedSeconds: 300)) == .none)
    }
}
