import Foundation

/// The Call Corpus export ENGINE (Part B): given the Store + a target folder, writes one clean file per
/// call (`.md` + `.json`) into `calls/` and maintains `index.jsonl` — cheap-skip unchanged, rewrite
/// changed, rename-reconcile on a title change, prune deleted-local, all via atomic writes. Free of
/// UI/config/scheduling (that lives in the App-layer `CorpusExportService`), so it is unit-testable
/// against a temp folder + a seeded Store. All work is synchronous + `Sendable`-safe → callers run it off
/// the main thread.
public enum CorpusExportEngine {

    /// Marks a folder as Recap-owned so the sync layer (B6) only ever `--delete`s inside it.
    public static let markerFile = ".callbrain-corpus"

    enum BuildResult: Equatable { case built(CorpusCall); case empty; case vanished }

    /// Run one export pass. `verify == true` rebuilds AND rewrites every call (self-heal for hand-edited /
    /// corrupted files — "Export all now"); `false` uses the cheap `updated_at` + `content_hash` skip.
    /// Returns the resulting ledger size (number of exported calls).
    ///
    /// Safety order: write new/changed files → write index → THEN garbage-collect unreferenced files. So the
    /// index never points at a deleted file, and a Store-read failure (which THROWS) aborts the pass before
    /// any index update or deletion, leaving the previous consistent state on disk untouched.
    @discardableResult
    public static func run(store: Store, folder: URL, verify: Bool, now: Date) throws -> Int {
        let fm = FileManager.default
        let callsDir = folder.appendingPathComponent("calls", isDirectory: true)
        try scaffold(folder: folder, callsDir: callsDir, fm: fm)

        var ledger = loadLedger(folder: folder, fm: fm)
        let manifest = try store.exportManifest()
        let live = Set(manifest.map(\.id))
        var claimed: [String: String] = [:] // stem -> id — GUARANTEES one file per id (fulfils B1's delegation)

        // Pass 1: cheap-skip unchanged (unless verify) and reserve their stems. The skip ALSO requires both
        // files to still exist on disk, so a hand-deleted file is healed on the next incremental run (not
        // only under verify) — keeping the invariant "the index only references files that exist".
        var toProcess: [Store.ExportManifestRow] = []
        for row in manifest {
            if !verify, let prev = ledger[row.id],
               prev.contentHash == row.contentHash, prev.updatedAt == row.updatedAt,
               fm.fileExists(atPath: folder.appendingPathComponent(prev.file).path),
               fm.fileExists(atPath: folder.appendingPathComponent(prev.json).path) {
                claimed[stemName(fromRelative: prev.file)] = row.id
            } else {
                toProcess.append(row)
            }
        }

        // Pass 2: (re)build + write. `buildCall` THROWS on a Store-read failure → the run aborts here, before
        // any index write or deletion, so a transient error can never delete or degrade a good export.
        for row in toProcess {
            switch try buildCall(store: store, id: row.id) {
            case .vanished:
                // Deleted between the manifest read and now — keep the prior entry; the next run prunes it.
                if let prev = ledger[row.id] { claimed[stemName(fromRelative: prev.file)] = row.id }
            case .empty:
                // Meeting present, reads succeeded, but no summary AND no transcript → drop it (GC removes its file).
                ledger[row.id] = nil
            case .built(let call):
                let hash = CallCorpusFormatter.exportHash(call)
                let base = CallCorpusFormatter.filenameStem(date: call.date, title: call.title, id: call.id)
                let stem = uniqueStem(base: base, forID: row.id, claimed: claimed)
                claimed[stem] = row.id
                let entry = CallCorpusFormatter.indexEntry(call, stem: stem, exportedAt: now, exportHash: hash)
                let md = CallCorpusFormatter.markdown(call, exportedAt: now, exportHash: hash)
                let jsonData = CallCorpusFormatter.json(call, exportedAt: now)
                try Data(md.utf8).write(to: callsDir.appendingPathComponent("\(stem).md"), options: .atomic)
                try jsonData.write(to: callsDir.appendingPathComponent("\(stem).json"), options: .atomic)
                ledger[row.id] = entry
            }
        }

        // Prune deleted-local calls (drop entries; GC removes their files below).
        for id in ledger.keys where !live.contains(id) { ledger[id] = nil }

        try writeIndex(ledger, folder: folder, fm: fm)
        // GC LAST: delete any calls/*.md|*.json the FINAL ledger no longer references — old rename stems,
        // pruned/empty calls, and orphans left by a corrupted ledger line. Only unreferenced files, so a
        // live call's file can never be clobbered. Throws on failure so a stale file isn't silently kept.
        try garbageCollect(ledger: ledger, callsDir: callsDir, fm: fm)
        return ledger.count
    }

    // MARK: - Build one call from the Store (read-only)

    /// Reads throw on failure (propagated so the pass aborts intact). `.vanished` = the meeting disappeared
    /// mid-pass; `.empty` = present but no summary AND no transcript (never write a dataless file).
    static func buildCall(store: Store, id: String) throws -> BuildResult {
        guard let meeting = try store.meeting(id: id) else { return .vanished }
        let meta = try store.exportMeta(id: id)
        let notes = try store.userNotes(meetingID: id)

        let utterances = try store.utterances(meetingID: id)
        let turns: [CorpusTurn]
        if !utterances.isEmpty {
            turns = utterances.map { CorpusTurn(t: $0.tStart, speaker: $0.speaker, inferred: $0.isInferred, text: $0.text) }
        } else {
            turns = try store.transcript(meetingID: id).map {
                CorpusTurn(t: $0.tStart, speaker: $0.speaker, inferred: false, text: $0.text)
            }
        }

        let items = try store.tasks(meetingID: id).map {
            CorpusActionItem(owner: $0.owner, text: $0.text, status: $0.status == .done ? "done" : "open")
        }
        let people = try store.meetingPeople(ids: [id], perMeeting: 64)[id] ?? []
        let duration = try store.meetingDurations(ids: [id])[id].map { Int($0.rounded()) } ?? meta?.durationColumn

        let hasSummary = (meeting.callSummary?.isEmpty == false) || (meeting.aiSummary?.isEmpty == false)
        guard hasSummary || !turns.isEmpty else { return .empty }

        return .built(CorpusCall(
            id: meeting.id, title: meeting.displayTitle, originalTitle: meeting.title, date: meeting.date,
            startTime: meta?.startTime, durationSeconds: duration, source: meeting.source,
            company: meta?.company, category: meeting.category, categoryConfidence: meta?.categoryConfidence,
            summarySource: meeting.summarySource, participants: people, oneLiner: meeting.aiSummary,
            userNotes: notes, summary: meeting.callSummary, actionItems: items, transcript: turns,
            contentHash: meta?.contentHash, updatedAt: meta?.updatedAt ?? ""))
    }

    // MARK: - Ledger + files

    static func loadLedger(folder: URL, fm: FileManager) -> [String: CorpusIndexEntry] {
        let indexURL = folder.appendingPathComponent("index.jsonl")
        guard let content = try? String(contentsOf: indexURL, encoding: .utf8) else { return [:] }
        var out: [String: CorpusIndexEntry] = [:]
        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            if let entry = CallCorpusFormatter.parseIndexLine(String(line)) { out[entry.id] = entry }
        }
        return out
    }

    static func writeIndex(_ ledger: [String: CorpusIndexEntry], folder: URL, fm: FileManager) throws {
        let sorted = ledger.values.sorted { ($0.date, $0.id) < ($1.date, $1.id) }
        let body = sorted.map(CallCorpusFormatter.indexLine).joined(separator: "\n")
        let content = body.isEmpty ? "" : body + "\n"
        try Data(content.utf8).write(to: folder.appendingPathComponent("index.jsonl"), options: .atomic)
    }

    /// Delete every `.md`/`.json` in `calls/` that the FINAL ledger doesn't reference. Runs after the index
    /// is written, so it only ever removes truly-unreferenced files (old rename stems, pruned/empty calls,
    /// orphans from a corrupted ledger line) — a live call's file is always referenced and preserved.
    static func garbageCollect(ledger: [String: CorpusIndexEntry], callsDir: URL, fm: FileManager) throws {
        let referenced = Set(ledger.values.flatMap {
            [($0.file as NSString).lastPathComponent, ($0.json as NSString).lastPathComponent]
        })
        let names = try fm.contentsOfDirectory(atPath: callsDir.path)
        for name in names where (name.hasSuffix(".md") || name.hasSuffix(".json")) && !referenced.contains(name) {
            try fm.removeItem(at: callsDir.appendingPathComponent(name))
        }
    }

    /// "calls/<stem>.md" → "<stem>".
    static func stemName(fromRelative relative: String) -> String {
        let base = (relative as NSString).lastPathComponent
        return (base as NSString).deletingPathExtension
    }

    /// Guarantee one filename per id: reuse `base` unless a DIFFERENT id already claimed it (the
    /// astronomically-rare 64-bit hash collision), in which case append `-2`, `-3`, …
    static func uniqueStem(base: String, forID id: String, claimed: [String: String]) -> String {
        if claimed[base] == nil || claimed[base] == id { return base }
        var n = 2
        while let owner = claimed["\(base)-\(n)"], owner != id { n += 1 }
        return "\(base)-\(n)"
    }

    static func scaffold(folder: URL, callsDir: URL, fm: FileManager) throws {
        try fm.createDirectory(at: callsDir, withIntermediateDirectories: true)
        let marker = folder.appendingPathComponent(markerFile)
        if !fm.fileExists(atPath: marker.path) {
            try? Data("Recap call corpus — do not edit; files are regenerated.\n".utf8).write(to: marker)
        }
        let readme = folder.appendingPathComponent("README.md")
        if !fm.fileExists(atPath: readme.path) {
            let text = """
            # Recap call corpus

            One file per call, written automatically by Recap:
            - `calls/<date>-<title>-<id>.md` — human/LLM-readable (frontmatter + full transcript)
            - `calls/<date>-<title>-<id>.json` — the same data, structured
            - `index.jsonl` — one line per call for fast indexing (id, title, participants, hashes)

            Files here are OVERWRITTEN by Recap — do not hand-edit. Deleting a call in Recap
            removes its files here on the next sync.
            """
            try? Data(text.utf8).write(to: readme, options: .atomic)
        }
    }
}
