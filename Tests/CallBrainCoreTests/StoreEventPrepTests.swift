import Testing
import Foundation
@testable import CallBrainCore

/// Calendar v4 — the prep-brief cache (v15). Round-trips, per-template keying, and
/// hash-based staleness (a changed source hash reads as a miss so the UI regenerates).
@Suite("Event prep store (v4)")
struct StoreEventPrepTests {

    private func freshStore() throws -> Store {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("cb-prep-\(UUID().uuidString).sqlite").path
        return try Store(path: path)
    }

    @Test("save + read round-trips when the source hash matches")
    func testRoundTrip() throws {
        let store = try freshStore()
        try store.savePrep(eventID: "eventKit|e1", template: "brief", sourceHash: "h1",
                           briefMD: "**Prep**\n- do the thing", model: "opus")
        let got = try store.prep(eventID: "eventKit|e1", template: "brief", sourceHash: "h1")
        #expect(got?.briefMD == "**Prep**\n- do the thing")
        #expect(got?.model == "opus")
    }

    @Test("a changed source hash reads as a miss (stale → regenerate)")
    func testStaleMiss() throws {
        let store = try freshStore()
        try store.savePrep(eventID: "eventKit|e1", template: "brief", sourceHash: "h1",
                           briefMD: "old", model: nil)
        #expect(try store.prep(eventID: "eventKit|e1", template: "brief", sourceHash: "h2") == nil)
        #expect(try store.prep(eventID: "eventKit|e1", template: "brief", sourceHash: "h1")?.briefMD == "old")
    }

    @Test("templates are keyed independently for the same event")
    func testPerTemplate() throws {
        let store = try freshStore()
        try store.savePrep(eventID: "e", template: "brief", sourceHash: "h", briefMD: "B", model: nil)
        try store.savePrep(eventID: "e", template: "talkingPoints", sourceHash: "h", briefMD: "TP", model: nil)
        #expect(try store.prep(eventID: "e", template: "brief", sourceHash: "h")?.briefMD == "B")
        #expect(try store.prep(eventID: "e", template: "talkingPoints", sourceHash: "h")?.briefMD == "TP")
    }

    @Test("upsert replaces the brief for the same (event, template)")
    func testUpsert() throws {
        let store = try freshStore()
        try store.savePrep(eventID: "e", template: "brief", sourceHash: "h1", briefMD: "v1", model: nil)
        try store.savePrep(eventID: "e", template: "brief", sourceHash: "h2", briefMD: "v2", model: "opus")
        let got = try store.prep(eventID: "e", template: "brief", sourceHash: "h2")
        #expect(got?.briefMD == "v2")
    }

    @Test("deletePrep clears every template for an event")
    func testDelete() throws {
        let store = try freshStore()
        try store.savePrep(eventID: "e", template: "brief", sourceHash: "h", briefMD: "B", model: nil)
        try store.savePrep(eventID: "e", template: "openQuestions", sourceHash: "h", briefMD: "Q", model: nil)
        #expect(try store.deletePrep(eventID: "e") == 2)
        #expect(try store.prep(eventID: "e", template: "brief", sourceHash: "h") == nil)
    }
}
