import Testing
import Foundation
@testable import CallBrainCore

/// B2 — read-only export APIs: the cheap change-detection manifest + the frontmatter columns that
/// `MeetingRow` doesn't carry. No migration; these must reflect exactly what `saveMeeting` persists.
@Suite("Store export read APIs")
struct StoreExportTests {

    private func freshStore() throws -> Store {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("cb-export-\(UUID().uuidString).sqlite").path
        return try Store(path: path)
    }

    @Test("exportManifest lists every meeting with updated_at + content_hash, no transcript needed")
    func manifest() throws {
        let store = try freshStore()
        try store.saveMeeting(Meeting(id: "m1", title: "A", date: "2026-07-01", source: .fireflies,
                                      contentFingerprint: "blake3:aaa"), chunks: [])
        try store.saveMeeting(Meeting(id: "m2", title: "B", date: "2026-07-02", source: .gmeetGemini),
                              chunks: [])

        let manifest = try store.exportManifest()
        #expect(manifest.count == 2)
        let byID = Dictionary(uniqueKeysWithValues: manifest.map { ($0.id, $0) })
        #expect(byID["m1"]?.contentHash == "blake3:aaa")
        #expect(byID["m2"]?.contentHash == nil)
        #expect((byID["m1"]?.updatedAt.isEmpty == false)) // updated_at populated by saveMeeting
    }

    @Test("exportMeta returns the frontmatter columns MeetingRow lacks; nil for a missing id")
    func meta() throws {
        let store = try freshStore()
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        try store.saveMeeting(Meeting(id: "m1", title: "Sync", date: "2026-07-01", startedAt: started,
                                      durationSeconds: 1830, source: .gmeetGemini, company: "Acme",
                                      contentFingerprint: "blake3:bbb"), chunks: [])

        let meta = try #require(try store.exportMeta(id: "m1"))
        #expect(meta.company == "Acme")
        #expect(meta.durationColumn == 1830)
        #expect(meta.contentHash == "blake3:bbb")
        #expect(meta.startTime != nil) // ISO8601 of `started`
        #expect(meta.updatedAt.isEmpty == false)
        #expect(meta.categoryConfidence == nil) // not set until classification runs

        #expect(try store.exportMeta(id: "nope") == nil)
    }
}
