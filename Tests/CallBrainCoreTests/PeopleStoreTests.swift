import Testing
import Foundation
@testable import CallBrainCore

/// Perfection plan Task 8.2 — the People read path: who shows up across your calls, junk
/// entities filtered, and a person's meetings + owned tasks for the detail page.
@Suite("People store queries (Task 8.2)")
struct PeopleStoreTests {

    private func seeded() throws -> Store {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("cb-people-\(UUID().uuidString).sqlite").path
        let store = try Store(path: path)
        for (i, date) in ["2026-06-28", "2026-06-30"].enumerated() {
            let mid = "m\(i)"
            let extra = i == 0
                ? Store.EntityInput(name: "Bundling", kind: "person", count: 2)   // junk NER token
                : Store.EntityInput(name: "Priya", kind: "person", count: 3)
            try store.saveMeeting(Meeting(id: mid, title: "Call \(i)", date: date, source: .fireflies),
                chunks: [Store.ChunkInput(chunkID: "\(mid)c0", meetingID: mid, version: 0, seq: 0,
                                          speaker: "Riley", tStart: 0, tEnd: 5, text: "hello",
                                          contentHash: "b:\(mid)c0")],
                entities: [Store.EntityInput(name: "Riley Novak", kind: "person", count: 6), extra],
                tasks: i == 1 ? [Store.TaskInput(id: "t1", owner: "Riley", text: "Ship billing", dedupeKey: "riley|ship billing")] : [])
        }
        return store
    }

    @Test("people aggregates across meetings; single-meeting one-word junk filtered")
    func testPeopleAggregation() throws {
        let store = try seeded()
        let people = try store.people()
        let names = people.map(\.name)
        #expect(names.contains("Riley Novak"))                    // 2 meetings + has a space
        #expect(!names.contains("Bundling"))                      // 1 meeting, single word → junk
        let riley = try #require(people.first(where: { $0.name == "Riley Novak" }))
        #expect(riley.meetingCount == 2)
        #expect(riley.lastSeen == "2026-06-30")
    }

    @Test("personDetail returns their meetings and owned tasks")
    func testPersonDetail() throws {
        let store = try seeded()
        let d = try store.personDetail(name: "Riley")
        #expect(d.meetings.count == 2)
        #expect(d.openTasks.count == 1)
        #expect(d.openTasks.first?.item.text == "Ship billing")
    }
}
