import Testing
@testable import CallBrainAppCore

/// The catch-up assistant + auto-notes must read named Meet captions when they exist, and only fall back
/// to the You/Them audio transcript when there are none — the fix for "Them has a PR…".
@Suite struct LiveTranscriptSourceTests {
    @Test func prefersNamedCaptionsWhenPresent() {
        let captions = "Alex Rivera: I opened a PR\nSam Chen: nice"
        let audio = "Them: I opened a PR\nYou: nice"
        #expect(preferredLiveTranscript(captions: captions, audio: audio) == captions)
    }

    @Test func fallsBackToAudioWhenNoCaptions() {
        let audio = "Them: hello\nYou: hi"
        #expect(preferredLiveTranscript(captions: "", audio: audio) == audio)
    }

    @Test func emptyWhenNeitherSourceHasContent() {
        #expect(preferredLiveTranscript(captions: "", audio: "") == "")
    }
}
