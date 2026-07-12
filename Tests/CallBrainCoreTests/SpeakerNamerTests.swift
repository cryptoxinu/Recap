import Testing
import Foundation
@testable import CallBrainCore

/// Task 8.1 — speaker naming: prompt contract, confidence gating, rename backfill.
@Suite("Speaker naming (Task 8.1)")
struct SpeakerNamerTests {

    @Test("needsNaming detects diarized labels only")
    func testNeedsNaming() {
        #expect(SpeakerNamer.needsNaming(speakers: ["Speaker 1", "Speaker 2"]))
        #expect(!SpeakerNamer.needsNaming(speakers: ["Riley", "Alex"]))
    }

    @Test("parse gates on confidence, UNKNOWN, valid names, and duplicate speakers")
    func testParseGating() {
        let json = """
        Here you go: [
          {"speaker": "Speaker 1", "name": "Riley Novak", "confidence": 0.9},
          {"speaker": "Speaker 2", "name": "UNKNOWN", "confidence": 0.9},
          {"speaker": "Speaker 3", "name": "Priya", "confidence": 0.4},
          {"speaker": "Speaker 1", "name": "Alex", "confidence": 0.95},
          {"speaker": "Speaker 9", "name": "Riley Novak", "confidence": 0.9},
          {"speaker": "Speaker 4", "name": "Dr Evil", "confidence": 0.99}
        ]
        """
        let out = SpeakerNamer.parse(json,
                                     validSpeakers: ["Speaker 1", "Speaker 2", "Speaker 3", "Speaker 4"],
                                     validNames: ["Riley Novak", "Priya", "Alex"])
        #expect(out == [SpeakerNamer.Mapping(speaker: "Speaker 1", name: "Riley Novak", confidence: 0.9)])
    }

    @Test("renameSpeaker backfills utterances + chunks (FTS follows via triggers)")
    func testRenameBackfill() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("cb-spk-\(UUID().uuidString).sqlite").path
        let store = try Store(path: path)
        try store.saveMeeting(Meeting(id: "m1", title: "call", date: "2026-06-30", source: .gmeetLocal),
            chunks: [Store.ChunkInput(chunkID: "c1", meetingID: "m1", version: 0, seq: 0,
                                      speaker: "Speaker 1", tStart: 0, tEnd: 5,
                                      text: "we should ship the billing fix", contentHash: "b:c1")],
            utterances: [Store.UtteranceInput(id: "u1", meetingID: "m1", version: 0, seq: 0,
                                              speaker: "Speaker 1", personID: nil, speakerConfidence: nil,
                                              isInferredSpeaker: true, tStart: 0, tEnd: 5,
                                              tsConfidence: "inferred", text: "we should ship the billing fix")])
        let changed = try store.renameSpeaker(meetingID: "m1", from: "Speaker 1", to: "Riley Novak")
        #expect(changed.utterances == 1 && changed.chunks == 1)
        #expect(try store.keywordSearch("billing", limit: 5).first?.speaker == "Riley Novak")
    }
}
