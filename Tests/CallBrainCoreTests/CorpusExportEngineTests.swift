import Testing
import Foundation
@testable import CallBrainCore

/// B3 — the export engine's incremental behaviour: cheap-skip unchanged, rewrite changed, rename-reconcile
/// on a title change, prune deleted-local, skip empty meetings, atomic writes. Runs against a temp folder +
/// a seeded Store.
@Suite("Corpus export engine")
struct CorpusExportEngineTests {

    private func freshStore() throws -> Store {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("cb-cx-\(UUID().uuidString).sqlite").path
        return try Store(path: path)
    }

    private func tempFolder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("cb-corpus-\(UUID().uuidString)")
    }

    private let now1 = Date(timeIntervalSince1970: 1000)
    private let now2 = Date(timeIntervalSince1970: 2000)

    /// Seed a meeting WITH a transcript chunk (so it is non-empty and gets exported).
    private func seed(_ store: Store, id: String, title: String, date: String = "2026-07-01",
                      text: String = "hello there") throws {
        try store.saveMeeting(
            Meeting(id: id, title: title, date: date, source: .fireflies, contentFingerprint: "blake3:\(id)"),
            chunks: [Store.ChunkInput(chunkID: "c-\(id)", meetingID: id, version: 0, seq: 0,
                                      speaker: "Alice", tStart: 0, tEnd: 1, text: text,
                                      contentHash: "h-\(id)")])
    }

    private func force(_ store: Store, id: String, updatedAt: String) throws {
        try store.dbQueue.write { db in
            try db.execute(sql: "UPDATE meetings SET updated_at = ? WHERE id = ?", arguments: [updatedAt, id])
        }
    }

    private func exportedAtByID(_ folder: URL) -> [String: String] {
        guard let content = try? String(contentsOf: folder.appendingPathComponent("index.jsonl"), encoding: .utf8)
        else { return [:] }
        var out: [String: String] = [:]
        for line in content.split(separator: "\n") {
            if let entry = CallCorpusFormatter.parseIndexLine(String(line)) { out[entry.id] = entry.exportedAt }
        }
        return out
    }

    private func callFiles(_ folder: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("calls").path)) ?? []
    }

    @Test("first run writes .md + .json + index.jsonl; a second unchanged run rewrites nothing")
    func idempotency() throws {
        let store = try freshStore()
        try seed(store, id: "m1", title: "Alpha")
        try seed(store, id: "m2", title: "Beta")
        let folder = tempFolder()

        #expect(try CorpusExportEngine.run(store: store, folder: folder, verify: false, now: now1) == 2)
        #expect(callFiles(folder).count == 4) // 2 md + 2 json
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(".callbrain-corpus").path))
        let a1 = exportedAtByID(folder)
        #expect(a1.count == 2)

        // Nothing changed → same exported_at (files were not rewritten).
        #expect(try CorpusExportEngine.run(store: store, folder: folder, verify: false, now: now2) == 2)
        #expect(exportedAtByID(folder) == a1)
        #expect(callFiles(folder).count == 4)
    }

    @Test("only the changed call is rewritten")
    func rewriteOnlyChanged() throws {
        let store = try freshStore()
        try seed(store, id: "m1", title: "Alpha")
        try seed(store, id: "m2", title: "Beta")
        let folder = tempFolder()
        _ = try CorpusExportEngine.run(store: store, folder: folder, verify: false, now: now1)
        let a1 = exportedAtByID(folder)

        try force(store, id: "m1", updatedAt: "2099-01-01 00:00:00") // dirty-mark m1 only
        _ = try CorpusExportEngine.run(store: store, folder: folder, verify: false, now: now2)
        let a2 = exportedAtByID(folder)

        #expect(a2["m1"] != a1["m1"]) // rewritten
        #expect(a2["m2"] == a1["m2"]) // skipped
    }

    @Test("a title change moves the file stem and deletes the old file (no orphan)")
    func renameReconcile() throws {
        let store = try freshStore()
        try seed(store, id: "m1", title: "Old Title")
        let folder = tempFolder()
        _ = try CorpusExportEngine.run(store: store, folder: folder, verify: false, now: now1)
        let stem1 = Set(callFiles(folder))
        #expect(stem1.count == 2)

        try store.dbQueue.write { db in
            try db.execute(sql: "UPDATE meetings SET ai_title = ?, updated_at = ? WHERE id = ?",
                           arguments: ["Brand New Name", "2099-01-01 00:00:00", "m1"])
        }
        _ = try CorpusExportEngine.run(store: store, folder: folder, verify: false, now: now2)
        let stem2 = Set(callFiles(folder))
        #expect(stem2.count == 2)          // still exactly one call's files…
        #expect(stem2.isDisjoint(with: stem1)) // …under a NEW stem; the old files were removed
        #expect(stem2.contains { $0.contains("brand-new-name") })
    }

    @Test("deleting a call locally prunes its files and index entry")
    func pruneOnDelete() throws {
        let store = try freshStore()
        try seed(store, id: "m1", title: "Alpha")
        try seed(store, id: "m2", title: "Beta")
        let folder = tempFolder()
        _ = try CorpusExportEngine.run(store: store, folder: folder, verify: false, now: now1)
        #expect(callFiles(folder).count == 4)

        try store.dbQueue.write { db in try db.execute(sql: "DELETE FROM meetings WHERE id = 'm2'") }
        #expect(try CorpusExportEngine.run(store: store, folder: folder, verify: false, now: now2) == 1)
        #expect(callFiles(folder).count == 2)
        #expect(exportedAtByID(folder).keys.sorted() == ["m1"])
    }

    @Test("an empty meeting (no summary, no transcript) is skipped — no dataless file")
    func emptySkip() throws {
        let store = try freshStore()
        try store.saveMeeting(Meeting(id: "empty", title: "Nothing", date: "2026-07-01", source: .manual),
                              chunks: []) // no transcript, no summary
        let folder = tempFolder()
        #expect(try CorpusExportEngine.run(store: store, folder: folder, verify: false, now: now1) == 0)
        #expect(callFiles(folder).isEmpty)
    }

    @Test("no temp files are left behind (atomic writes)")
    func noTempLeftovers() throws {
        let store = try freshStore()
        try seed(store, id: "m1", title: "Alpha")
        let folder = tempFolder()
        _ = try CorpusExportEngine.run(store: store, folder: folder, verify: false, now: now1)
        #expect(callFiles(folder).allSatisfy { $0.hasSuffix(".md") || $0.hasSuffix(".json") })
    }

    @Test("verify (Export all now) rewrites everything, self-healing a deleted file")
    func verifySelfHeal() throws {
        let store = try freshStore()
        try seed(store, id: "m1", title: "Alpha")
        let folder = tempFolder()
        _ = try CorpusExportEngine.run(store: store, folder: folder, verify: false, now: now1)
        let dir = folder.appendingPathComponent("calls")
        let md = try #require(callFiles(folder).first { $0.hasSuffix(".md") })
        try FileManager.default.removeItem(at: dir.appendingPathComponent(md)) // simulate a hand-deleted file
        #expect(callFiles(folder).count == 1)

        _ = try CorpusExportEngine.run(store: store, folder: folder, verify: true, now: now2)
        #expect(callFiles(folder).count == 2) // healed
    }

    @Test("an incremental run heals a hand-deleted file (index never references a missing file)")
    func incrementalHeal() throws {
        let store = try freshStore()
        try seed(store, id: "m1", title: "Alpha")
        let folder = tempFolder()
        _ = try CorpusExportEngine.run(store: store, folder: folder, verify: false, now: now1)
        let md = try #require(callFiles(folder).first { $0.hasSuffix(".md") })
        try FileManager.default.removeItem(at: folder.appendingPathComponent("calls").appendingPathComponent(md))
        #expect(callFiles(folder).count == 1)
        // A plain incremental re-run (not verify) rebuilds the missing file.
        _ = try CorpusExportEngine.run(store: store, folder: folder, verify: false, now: now2)
        #expect(callFiles(folder).count == 2)
    }

    @Test("buildCall distinguishes a genuinely-empty meeting from a present one with content")
    func buildResults() throws {
        let store = try freshStore()
        try store.saveMeeting(Meeting(id: "empty", title: "x", date: "2026-07-01", source: .manual), chunks: [])
        try seed(store, id: "full", title: "y")
        #expect(try CorpusExportEngine.buildCall(store: store, id: "empty") == .empty)
        #expect(try CorpusExportEngine.buildCall(store: store, id: "gone") == .vanished)
        if case .built = try CorpusExportEngine.buildCall(store: store, id: "full") {} else {
            Issue.record("expected .built for a meeting with a transcript")
        }
    }

    @Test("uniqueStem guarantees one filename per id, disambiguating a collision between different ids")
    func uniqueStem() {
        #expect(CorpusExportEngine.uniqueStem(base: "s", forID: "a", claimed: [:]) == "s")
        #expect(CorpusExportEngine.uniqueStem(base: "s", forID: "a", claimed: ["s": "a"]) == "s") // same id reuses
        #expect(CorpusExportEngine.uniqueStem(base: "s", forID: "b", claimed: ["s": "a"]) == "s-2") // collision
        #expect(CorpusExportEngine.uniqueStem(base: "s", forID: "c",
                                              claimed: ["s": "a", "s-2": "b"]) == "s-3")
    }
}
