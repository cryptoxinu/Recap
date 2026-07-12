import Testing
import Foundation
@testable import CallBrainCore

/// Tidy's undo (Part 3, 2026-07-11) reverts a run using exactly these Store operations — restore
/// reworded text/owner, reopen completed/deduped, delete additions. These lock in that each is truly
/// reversible (Tidy never hard-deletes, so a run can always be put back the way it was).
@Suite("Tidy undo primitives")
struct TidyUndoPrimitivesTests {
    private func store() throws -> Store {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("cb-undo-\(UUID().uuidString).sqlite").path
        let s = try Store(path: path)
        try s.saveMeeting(Meeting(id: "m0", title: "Sync", date: "2026-07-10", source: .manual),
            chunks: [Store.ChunkInput(chunkID: "m0c0", meetingID: "m0", version: 0, seq: 0,
                                      speaker: "S", tStart: 0, tEnd: 1, text: "x", contentHash: "b:m0c0")],
            tasks: [Store.TaskInput(id: "orig1", owner: "Sam", text: "send the deck", dedupeKey: "k1")])
        return s
    }

    @Test("reword is reversible — restoring prior text + owner puts the task back")
    func rewordUndo() throws {
        let s = try store()
        try s.updateTaskText(id: "orig1", text: "SEND THE FINAL DECK TO SAM", owner: "Alex")
        #expect(try s.tasks().first { $0.item.id == "orig1" }?.item.text == "SEND THE FINAL DECK TO SAM")
        // undo:
        try s.updateTaskText(id: "orig1", text: "send the deck", owner: "Sam")
        let r = try s.tasks().first { $0.item.id == "orig1" }
        #expect(r?.item.text == "send the deck" && r?.item.owner == "Sam")
    }

    @Test("complete/dedup is reversible — reopening a Tidy-completed task restores it as open")
    func reopenUndo() throws {
        let s = try store()
        #expect(try s.setTaskStatus(id: "orig1", .done) == true)
        #expect(try s.tasks(status: .open).contains { $0.item.id == "orig1" } == false)
        // undo:
        _ = try s.setTaskStatus(id: "orig1", .open)
        #expect(try s.tasks(status: .open).contains { $0.item.id == "orig1" } == true)
    }

    @Test("add is reversible — deleting the returned new id removes the addition")
    func addUndo() throws {
        let s = try store()
        let newID = try #require(try s.addReconciledTask(meetingID: "m0", owner: "Sam", text: "book the venue"))
        #expect(try s.tasks().contains { $0.item.id == newID } == true)
        // undo:
        try s.deleteTasks(ids: [newID])
        #expect(try s.tasks().contains { $0.item.id == newID } == false)
        // the pre-existing task is untouched by the add-undo.
        #expect(try s.tasks().contains { $0.item.id == "orig1" } == true)
    }
}
