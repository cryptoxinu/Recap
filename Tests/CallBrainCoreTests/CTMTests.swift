import Testing
import Foundation
@testable import CallBrainCore

// First real tests: the Canonical Transcript Model must survive Codable round-trips
// (it's persisted + crosses actor boundaries) and produce correct, non-fabricated citations.

@Suite("Canonical Transcript Model")
struct CTMTests {

    @Test("Utterance round-trips through Codable unchanged")
    func utteranceCodableRoundTrip() throws {
        let u = Utterance(
            id: "u_000123", meetingID: "m1", version: 0, seq: 123,
            personID: "p_travis", speakerRaw: "Travis", speakerConfidence: 0.88,
            tStart: 742.30, tEnd: 768.11, text: "On Render, the GPU spot pricing…",
            isInferredSpeaker: false, tsConfidence: .exact
        )
        let data = try JSONEncoder().encode(u)
        let back = try JSONDecoder().decode(Utterance.self, from: data)
        #expect(back == u)
    }

    @Test("Meeting round-trips with participants + optional fields")
    func meetingCodableRoundTrip() throws {
        let m = Meeting(
            id: "m1", title: "Travis sync — Render GPU pricing", date: "2026-05-14",
            startedAt: Date(timeIntervalSince1970: 1_747_238_400), durationSeconds: 3120,
            source: .fathom, company: "Render",
            participants: [ParticipantRef(personID: "p_travis", rawLabel: "Travis", role: "speaker")],
            contentFingerprint: "blake3:abc", fileHash: "blake3:def"
        )
        let back = try JSONDecoder().decode(Meeting.self, from: JSONEncoder().encode(m))
        #expect(back == m)
        #expect(back.participants.first?.personID == "p_travis")
    }

    @Test("Citation deep link encodes the timestamp for transcript jump")
    func citationDeepLink() {
        let c = Citation(
            chunkID: "c1", meetingID: "m1", meetingTitle: "Travis sync — Render",
            meetingDate: "2026-05-14", speaker: "Travis", tStart: 742.30, tEnd: 768.11,
            source: .fathom, alsoInSources: [.fireflies], tsConfidence: .exact
        )
        #expect(c.deepLink == "callbrain://meeting/m1?t=742.30")
        #expect(c.alsoInSources == [.fireflies])
    }

    @Test("Citation with no timestamp falls back to t=0 (never fabricates a moment)")
    func citationNoTimestamp() {
        let c = Citation(
            chunkID: "c2", meetingID: "m2", meetingTitle: "Cluely note", meetingDate: "2026-05-10",
            speaker: "Max", tStart: nil, tEnd: nil, source: .cluely, tsConfidence: .none
        )
        #expect(c.deepLink == "callbrain://meeting/m2?t=0")
        #expect(c.tsConfidence == .none)
    }

    @Test("MeetingSource raw values match the DB source taxonomy")
    func sourceRawValues() {
        #expect(MeetingSource.gmeetGemini.rawValue == "gmeet_gemini")
        #expect(MeetingSource.gmeetLocal.rawValue == "gmeet_local")
        #expect(MeetingSource.srtVtt.rawValue == "srt_vtt")
        #expect(MeetingSource.allCases.count == 9)
    }
}
