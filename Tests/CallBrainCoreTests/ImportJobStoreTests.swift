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

    @Test("clearFinished removes done/failed only; keeps queued/running AND needsReview")
    func clearFinished() throws {
        let store = try freshStore()
        try store.upsertImportJob(ImportJob(id: "q", sourceName: "q", state: .queued, createdAt: 1))
        try store.upsertImportJob(ImportJob(id: "r", sourceName: "r", state: .running, createdAt: 2))
        try store.upsertImportJob(ImportJob(id: "d", sourceName: "d", state: .done, createdAt: 3))
        try store.upsertImportJob(ImportJob(id: "n", sourceName: "n", state: .needsReview, createdAt: 4))
        try store.upsertImportJob(ImportJob(id: "f", sourceName: "f", state: .failed, createdAt: 5))

        let removed = try store.clearFinishedImportJobs()
        #expect(removed == 2)                                       // done + failed only
        #expect(Set(try store.importJobs().map(\.id)) == ["q", "r", "n"])   // needsReview preserved
    }

    @Test("delete a single job by id")
    func deleteOne() throws {
        let store = try freshStore()
        try store.upsertImportJob(ImportJob(id: "x", sourceName: "x", state: .done, createdAt: 1))
        try store.deleteImportJob(id: "x")
        #expect(try store.importJobs().isEmpty)
    }

    @Test("payload (file path / pasted text) round-trips so a job survives relaunch")
    func payloadRoundTrip() throws {
        let store = try freshStore()
        try store.upsertImportJob(ImportJob(id: "f", sourceName: "a.docx", state: .queued, createdAt: 1,
                                            payloadKind: .file, payload: "/Users/z/a.docx"))
        try store.upsertImportJob(ImportJob(id: "p", sourceName: "Pasted text", state: .queued, createdAt: 2,
                                            payloadKind: .paste, payload: "Riley: hi"))
        let jobs = try store.importJobs()
        let f = jobs.first { $0.id == "f" }; let p = jobs.first { $0.id == "p" }
        #expect(f?.payloadKind == .file); #expect(f?.payload == "/Users/z/a.docx")
        #expect(p?.payloadKind == .paste); #expect(p?.payload == "Riley: hi")
    }

    @Test("pendingImportJobs returns ALL queued/running oldest-first (not display-limited)")
    func pendingUnbounded() throws {
        let store = try freshStore()
        for i in 0..<150 {
            try store.upsertImportJob(ImportJob(id: "j\(i)", sourceName: "f\(i)", state: .queued,
                                                createdAt: Double(i)))
        }
        try store.upsertImportJob(ImportJob(id: "done", sourceName: "d", state: .done, createdAt: 999))
        let pending = try store.pendingImportJobs()
        #expect(pending.count == 150)                         // not capped at 100
        #expect(pending.first?.id == "j0")                    // oldest first
        #expect(!pending.contains { $0.id == "done" })        // finished excluded
    }
}
