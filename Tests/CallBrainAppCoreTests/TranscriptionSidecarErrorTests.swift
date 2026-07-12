import Testing
@testable import CallBrainAppCore

/// P2c contract: the `cbtranscribe` helper signals "no speech" with a DEDICATED exit code so the
/// parent can create a findable placeholder meeting instead of dropping the recording as a generic
/// failure. These lock the code + the mapping so the helper and the runner can never drift apart.
@Suite("Transcription sidecar no-speech contract (P2c)")
struct TranscriptionSidecarErrorTests {

    @Test("no-speech exit code is the agreed sentinel (helper `exit(3)`)")
    func noSpeechExitCode() {
        #expect(TranscriptionSidecarError.noSpeechExitCode == 3)
    }

    @Test("noSpeech carries a human message and is distinct from a helper crash")
    func noSpeechDescription() {
        #expect(TranscriptionSidecarError.noSpeech.errorDescription?.isEmpty == false)
        #expect(TranscriptionSidecarError.noSpeech != .childFailed(status: 3, stderr: ""))
    }

    // Only a child CRASH escalates to a lighter model (the WhisperKit MLTensor SIGTRAP recovery). A clean
    // no-speech, a missing helper, or unreadable output are terminal — a different model won't change them.
    @Test("model-fallback escalates on a crash, not on no-speech / missing-helper / bad-output")
    func modelFallbackPolicy() {
        #expect(TranscriptionSidecarError.childFailed(status: 5, stderr: "SIGTRAP").isModelSpecificFailure)
        #expect(TranscriptionSidecarError.childFailed(status: 1, stderr: "err").isModelSpecificFailure)
        #expect(!TranscriptionSidecarError.noSpeech.isModelSpecificFailure)
        #expect(!TranscriptionSidecarError.helperUnavailable("/x").isModelSpecificFailure)
        #expect(!TranscriptionSidecarError.missingOutput("/x").isModelSpecificFailure)
        #expect(!TranscriptionSidecarError.invalidOutput("bad json").isModelSpecificFailure)
    }
}
