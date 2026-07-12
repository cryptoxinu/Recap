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

    @Test("raw spk/S/underscore tokens are generic; an already-clean 'Speaker N' is NOT (no renumber → no swap)")
    func handlesVariants() {
        #expect(SpeakerResolver.isGeneric("spk0"))
        #expect(SpeakerResolver.isGeneric("S2"))
        #expect(SpeakerResolver.isGeneric("Speaker_00"))
        #expect(!SpeakerResolver.isGeneric("Speaker 1"))   // already clean (space + number) — leave it alone
        #expect(!SpeakerResolver.isGeneric("Speaker 2"))
        let out = SpeakerResolver.resolve(["spk1", "spk2", "spk1"])
        #expect(out == ["Speaker 1", "Speaker 2", "Speaker 1"])
        // Clean "Speaker N" pass through unchanged even when they appear out of order (no swap).
        #expect(SpeakerResolver.resolve(["Speaker 2", "Speaker 1"]) == ["Speaker 2", "Speaker 1"])
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
        #expect(!SpeakerResolver.isGeneric("Alex"))
        #expect(!SpeakerResolver.isGeneric("Dom Lang"))
        let out = SpeakerResolver.resolve([" Alex ", "Dom Lang", "Alex"])
        #expect(out == ["Alex", "Dom Lang", "Alex"])
    }

    @Test("mixed real names + generic placeholders coexist")
    func mixed() {
        let out = SpeakerResolver.resolve(["Alex", "SPEAKER_00", "Alex", "SPEAKER_01"])
        #expect(out == ["Alex", "Speaker 1", "Alex", "Speaker 2"])
    }
}
