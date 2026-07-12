import Testing
import Foundation
@testable import CallBrainCore

@Suite("Store backup / restore (.cbk)")
struct BackupTests {
    private func freshStore() throws -> (Store, String) {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("cb-bk-\(UUID().uuidString).sqlite").path
        return (try Store(path: path), path)
    }

    @Test("backup writes a valid .cbk that round-trips the data")
    func roundTrip() async throws {
        let (store, _) = try freshStore()
        try store.saveMeeting(Meeting(id: "m1", title: "Backed-up call", date: "2026-06-30", source: .fireflies),
                              chunks: [Store.ChunkInput(chunkID: "c0", meetingID: "m1", version: 0, seq: 0,
                                       speaker: "Dom", tStart: 0, tEnd: 1, text: "hello world", contentHash: "h")])

        let cbk = FileManager.default.temporaryDirectory.appendingPathComponent("cb-\(UUID().uuidString).cbk")
        defer { try? FileManager.default.removeItem(at: cbk) }
        try store.backup(to: cbk)

        #expect(FileManager.default.fileExists(atPath: cbk.path))
        #expect(Store.isValidBackup(at: cbk))

        // open the backup as a store and confirm the data is there
        let restored = try Store(path: cbk.path)
        #expect(try restored.meetingCount() == 1)
        #expect(try restored.meeting(id: "m1")?.title == "Backed-up call")
    }

    @Test("a non-backup file is rejected")
    func rejectsJunk() throws {
        let junk = FileManager.default.temporaryDirectory.appendingPathComponent("cb-junk-\(UUID().uuidString).cbk")
        try "not a database".write(to: junk, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: junk) }
        #expect(Store.isValidBackup(at: junk) == false)
    }
}
