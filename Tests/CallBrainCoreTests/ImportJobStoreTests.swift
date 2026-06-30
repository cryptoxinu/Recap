import Testing
import Foundation
@testable import CallBrainCore

@Suite("Store: durable import-job queue")
struct ImportJobStoreTests {

    private func freshStore() throws -> Store {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("cb-jobs-\(UUID().uuidString).sqlite").path
        return try Store(path: path)
    }

    @Test("upsert → read back; newest first; update in place")
    func upsertAndRead() throws {
        let store = try freshStore()
        try store.upsertImportJob(ImportJob(id: "a", sourceName: "a.docx", state: .queued, createdAt: 100))
        try store.upsertImportJob(ImportJob(id: "b", sourceName: "b.txt", state: .running, createdAt: 200))
        // update "a" to done
        try store.upsertImportJob(ImportJob(id: "a", sourceName: "a.docx", state: .done,
                                            format: "geminiNotes", meetingID: "m1", title: "Morning",
                                            chunkCount: 9, createdAt: 100))
        let jobs = try store.importJobs()
        #expect(jobs.map(\.id) == ["b", "a"])              // created_at DESC
        let a = jobs.first { $0.id == "a" }
        #expect(a?.state == .done)
        #expect(a?.format == "geminiNotes")
        #expect(a?.meetingID == "m1")
        #expect(a?.chunkCount == 9)
    }

    @Test("clearFinished removes done/needsReview/failed, keeps queued/running")
    func clearFinished() throws {
        let store = try freshStore()
        try store.upsertImportJob(ImportJob(id: "q", sourceName: "q", state: .queued, createdAt: 1))
        try store.upsertImportJob(ImportJob(id: "r", sourceName: "r", state: .running, createdAt: 2))
        try store.upsertImportJob(ImportJob(id: "d", sourceName: "d", state: .done, createdAt: 3))
        try store.upsertImportJob(ImportJob(id: "n", sourceName: "n", state: .needsReview, createdAt: 4))
        try store.upsertImportJob(ImportJob(id: "f", sourceName: "f", state: .failed, createdAt: 5))

        let removed = try store.clearFinishedImportJobs()
        #expect(removed == 3)
        #expect(Set(try store.importJobs().map(\.id)) == ["q", "r"])
    }

    @Test("delete a single job by id")
    func deleteOne() throws {
        let store = try freshStore()
        try store.upsertImportJob(ImportJob(id: "x", sourceName: "x", state: .done, createdAt: 1))
        try store.deleteImportJob(id: "x")
        #expect(try store.importJobs().isEmpty)
    }
}
