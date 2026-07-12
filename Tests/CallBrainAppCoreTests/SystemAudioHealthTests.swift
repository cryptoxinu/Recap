import Testing
@testable import CallBrainAppCore

@Suite("System audio health")
struct SystemAudioHealthTests {
    @Test("missing system samples become a visible no-audio state")
    func missingSamplesBecomeNoAudioState() {
        let state = SystemAudioHealth.stateAfterWatchdog(
            includeSystemAudio: true,
            current: .capturing,
            receivedSamples: false
        )

        #expect(state == .noSamples)
    }

    @Test("received system samples stay in the recording-call-audio state")
    func receivedSamplesStayReceiving() {
        let state = SystemAudioHealth.stateAfterWatchdog(
            includeSystemAudio: true,
            current: .capturing,
            receivedSamples: true
        )

        #expect(state == .receiving)
    }

    @Test("stop warning says the recording is mic only when no system audio arrived")
    func stopWarningForMicOnlyRecording() {
        let warning = SystemAudioHealth.stopWarning(
            includeSystemAudio: true,
            state: .noSamples
        )

        #expect(warning?.contains("only your mic") == true)
    }

    @Test("stop warning includes setup failures without leaking implementation details")
    func stopWarningForSetupFailure() {
        let warning = SystemAudioHealth.stopWarning(
            includeSystemAudio: true,
            state: .failed("Screen Recording permission is off.")
        )

        #expect(warning == "System audio was not captured (Screen Recording permission is off.) - only your mic was recorded.")
    }
}
