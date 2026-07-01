import Testing
import Foundation
@testable import CallBrainCore

@Suite("SpeakerResolver (clean speaker display names)")
struct SpeakerResolverTests {

    @Test("raw diarization labels → Speaker 1/2/3 by first appearance")
    func renumbersDiarization() {
        let out = SpeakerResolver.resolve(["SPEAKER_00", "SPEAKER_01", "SPEAKER_00", "SPEAKER_02"])
        #expect(out == ["Speaker 1", "Speaker 2", "Speaker 1", "Speaker 3"])
    }

    @Test("already-numbered 'Speaker N' + spk/S variants are treated as generic and renumbered cleanly")
    func handlesVariants() {
        #expect(SpeakerResolver.isGeneric("Speaker 1"))
        #expect(SpeakerResolver.isGeneric("spk0"))
        #expect(SpeakerResolver.isGeneric("S2"))
        #expect(SpeakerResolver.isGeneric("Speaker_00"))
        let out = SpeakerResolver.resolve(["spk1", "spk2", "spk1"])
        #expect(out == ["Speaker 1", "Speaker 2", "Speaker 1"])
    }

    @Test("empty / — / Unknown / bare Speaker fallbacks are renumbered, not shown raw")
    func normalizesFallbacks() {
        #expect(SpeakerResolver.isGeneric(""))
        #expect(SpeakerResolver.isGeneric("—"))
        #expect(SpeakerResolver.isGeneric("Unknown"))
        #expect(SpeakerResolver.isGeneric("Speaker"))
        let out = SpeakerResolver.resolve(["", "Unknown", ""])
        #expect(out == ["Speaker 1", "Speaker 2", "Speaker 1"])   // each distinct raw → its own number
    }

    @Test("real names pass through trimmed and unchanged")
    func keepsRealNames() {
        #expect(!SpeakerResolver.isGeneric("Zade"))
        #expect(!SpeakerResolver.isGeneric("Max Lang"))
        let out = SpeakerResolver.resolve([" Zade ", "Max Lang", "Zade"])
        #expect(out == ["Zade", "Max Lang", "Zade"])
    }

    @Test("mixed real names + generic placeholders coexist")
    func mixed() {
        let out = SpeakerResolver.resolve(["Zade", "SPEAKER_00", "Zade", "SPEAKER_01"])
        #expect(out == ["Zade", "Speaker 1", "Zade", "Speaker 2"])
    }
}
