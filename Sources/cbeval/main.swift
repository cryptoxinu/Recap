import Foundation
import CallBrainCore

// cbeval — retrieval-quality eval CLI (perfection plan, Phase 0).
// Runs the checked-in gold set through the SAME hybrid retrieval the app uses and prints hit@k.
// Always operates on a throwaway READ-ONLY snapshot of the store — safe while the app runs.
// Usage:
//   swift run cbeval [--store <path>] [--gold <path>] [--k N] [--json]
// Defaults: snapshot of the app's store, Tests/Fixtures/eval/retrieval_gold.json, k=20.

func usage() -> Never {
    print("""
    cbeval — Recap retrieval eval (operates on a read-only snapshot; app can stay running)
      --store <path>   sqlite store to snapshot (default: ~/Library/Application Support/CallBrain/callbrain.sqlite3)
      --gold <path>    gold set JSON (default: Tests/Fixtures/eval/retrieval_gold.json)
      --k <n>          top-k window for a hit (default: 20 — matches autoTopK's ceiling)
      --json           machine-readable output
      ask "<question>" run ONE production-path ask (snapshot retrieval + real claude CLI, opus)
                       and print the per-stage AskMetrics — the latency-baseline tool (Task 0.3)
      backfill-dates   print the planned date repairs for transcribed meetings (reads a snapshot);
                       add --apply to write them to the REAL store (refuses while the app runs)
      link-candidates  print gemini-notes ↔ transcript pairs of the SAME call (reads a snapshot);
                       add --apply to MERGE them in the real store with conservation asserts
      dedupe-tasks     print open near-duplicate tasks left by merged call halves (snapshot);
                       add --apply to drop them from the real store
      audit-task-dedupe --backup <path>
                       retroactive evidence for applied task drops: reconstructs the merged task
                       sets from the pre-merge backup, recomputes with the STRICT rule, prints
                       each drop with its kept twin; --apply RESTORES drops the strict rule rejects
    """)
    exit(2)
}

func requireAppClosed() {
    let pgrep = Process()
    pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    pgrep.arguments = ["-f", "Recap.app/Contents/MacOS/Recap"]
    pgrep.standardOutput = Pipe(); pgrep.standardError = Pipe()
    try? pgrep.run(); pgrep.waitUntilExit()
    if pgrep.terminationStatus == 0 {
        FileHandle.standardError.write(Data("cbeval: quit Recap before --apply\n".utf8)); exit(1)
    }
}

var storePath = ("~/Library/Application Support/CallBrain/callbrain.sqlite3" as NSString).expandingTildeInPath
var goldPath = "Tests/Fixtures/eval/retrieval_gold.json"
var k = 20
var asJSON = false

var askQuestion: String? = nil
var backfillDates = false
var linkCandidates = false
var dedupeTasks = false
var auditTaskDedupe = false
var backupPath: String? = nil
var applyChanges = false
var streamAsk = false
var summarizeMeeting: String? = nil

var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--store": guard !args.isEmpty else { usage() }; storePath = (args.removeFirst() as NSString).expandingTildeInPath
    case "--gold":  guard !args.isEmpty else { usage() }; goldPath = args.removeFirst()
    case "--k":     guard let n = args.first.flatMap({ Int($0) }) else { usage() }; args.removeFirst(); k = n
    case "--json":  asJSON = true
    case "ask":     guard !args.isEmpty else { usage() }; askQuestion = args.removeFirst()
    case "summarize": guard !args.isEmpty else { usage() }; summarizeMeeting = args.removeFirst()
    case "backfill-dates": backfillDates = true
    case "link-candidates": linkCandidates = true
    case "dedupe-tasks": dedupeTasks = true
    case "audit-task-dedupe": auditTaskDedupe = true
    case "--backup": guard !args.isEmpty else { usage() }; backupPath = (args.removeFirst() as NSString).expandingTildeInPath
    case "--apply": applyChanges = true
    case "--stream": streamAsk = true
    default: usage()
    }
}

// Codex phase-0 HIGH: NEVER open the live store read-write (Store.init runs migrations + WAL
// PRAGMAs). Every cbeval mode operates on a throwaway read-only VACUUM snapshot instead — safe
// even while the app is running, and any migrator run mutates only the copy.
func snapshotted(_ livePath: String) throws -> String {
    let snap = FileManager.default.temporaryDirectory
        .appendingPathComponent("cbeval-snap-\(UUID().uuidString).sqlite3").path
    try Store.readOnlySnapshot(of: livePath, to: snap)
    return snap
}

// `link-candidates` mode (Task 2.3): pair the double-ingested halves; --apply merges them.
if linkCandidates {
    do {
        if applyChanges {
            requireAppClosed()
            let store = try Store(path: storePath)
            let preChunks = try store.chunkCount()
            let pairs = try CrossSourceLinker.candidates(store: store)
            var totals = Store.MergeStats()
            for p in pairs {
                print("MERGE  [\(p.reason)]")
                print("       notes:      \(p.gemini.title.prefix(58))")
                print("       transcript: \(p.transcript.title.prefix(58))")
                let s = try store.mergeMeetings(loserID: p.gemini.id, survivorID: p.transcript.id)
                totals.chunksMoved += s.chunksMoved; totals.tasksMoved += s.tasksMoved
                totals.tasksDeduped += s.tasksDeduped; totals.citationsRewritten += s.citationsRewritten
            }
            // Conservation asserts (Phase-2 exit criteria) — numbers go in the ledger.
            let postChunks = try store.chunkCount()
            let orphanTasks = try store.orphanTaskCount()
            print("merged \(pairs.count) pairs · chunks \(preChunks)→\(postChunks) (must be equal) · " +
                  "tasks moved \(totals.tasksMoved), deduped \(totals.tasksDeduped) · " +
                  "citations rewritten \(totals.citationsRewritten) · orphan tasks \(orphanTasks) (must be 0)")
            exit(preChunks == postChunks && orphanTasks == 0 ? 0 : 1)
        } else {
            let store = try Store(path: try snapshotted(storePath))
            let pairs = try CrossSourceLinker.candidates(store: store)
            if pairs.isEmpty { print("No linkable pairs found.") }
            for p in pairs {
                print("PAIR   [\(p.reason)]")
                print("       notes:      \(p.gemini.title.prefix(58))")
                print("       transcript: \(p.transcript.title.prefix(58))")
            }
            print("\(pairs.count) pair\(pairs.count == 1 ? "" : "s"). Re-run with --apply (app closed) to merge.")
        }
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("cbeval link-candidates: \(error)\n".utf8)); exit(1)
    }
}

// `audit-task-dedupe` mode (Codex phase-2 MED): prove or repair the applied drops. Ground truth
// for loser→survivor comes from chunk IDs (chunks moved, ids unchanged) — no re-pairing guesses.
if auditTaskDedupe {
    do {
        guard let backupPath else {
            FileHandle.standardError.write(Data("cbeval: audit-task-dedupe requires --backup <path>\n".utf8)); exit(1)
        }
        if applyChanges { requireAppClosed() }
        let bak = try Store(path: try snapshotted(backupPath))
        let live = try Store(path: applyChanges ? storePath : snapshotted(storePath))

        let liveMeetingIDs = Set(try live.meetings(fromYMD: "2000-01-01", toYMDExclusive: "2100-01-01", limit: 10_000).map(\.id))
        let bakMeetings = try bak.meetings(fromYMD: "2000-01-01", toYMDExclusive: "2100-01-01", limit: 10_000)

        // loser → survivor via chunk ground truth.
        var survivorOf: [String: String] = [:]
        for m in bakMeetings where !liveMeetingIDs.contains(m.id) {
            if let cid = try bak.chunkIDs(meetingID: m.id).first,
               let survivor = try live.chunks(ids: [cid]).first?.meetingID {
                survivorOf[m.id] = survivor
            }
        }

        var restored = 0, confirmedDrops = 0
        for survivor in liveMeetingIDs {
            let losers = survivorOf.filter { $0.value == survivor }.map(\.key)
            guard !losers.isEmpty else { continue }
            // The merged task set as it existed right after the merge (pre-dedupe).
            var mergedTasks: [(item: ActionItem, dedupeKey: String)] = []
            mergedTasks += try bak.tasksWithKeys(meetingID: survivor)
            for l in losers { mergedTasks += try bak.tasksWithKeys(meetingID: l) }
            let liveIDs = Set(try live.tasks(meetingID: survivor).map(\.id))
            let appliedDrops = mergedTasks.filter { !liveIDs.contains($0.item.id) }
            guard !appliedDrops.isEmpty else { continue }
            let strictDrops = Set(TaskIntelligence.crossHalfDedupePlan(mergedTasks.map(\.item)))
            for d in appliedDrops {
                if strictDrops.contains(d.item.id) {
                    confirmedDrops += 1
                    print("CONFIRMED  \(d.item.owner ?? "—"): \(d.item.text.prefix(64))")
                } else {
                    print("RESTORE\(applyChanges ? "D" : "?")   \(d.item.owner ?? "—"): \(d.item.text.prefix(64))")
                    if applyChanges {
                        try live.restoreTask(d.item, dedupeKey: d.dedupeKey, meetingID: survivor)
                    }
                    restored += 1
                }
            }
        }
        print("\(confirmedDrops) drops confirmed by the strict rule · \(restored) \(applyChanges ? "restored" : "would be restored (re-run with --apply)")")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("cbeval audit-task-dedupe: \(error)\n".utf8)); exit(1)
    }
}

// `dedupe-tasks` mode (Task 2.4): drop open near-duplicates left by merged call halves.
if dedupeTasks {
    do {
        // Guard BEFORE opening: Store.init runs WAL PRAGMAs + migrations on the live file
        // (Codex phase-2 HIGH: the old order was a real TOCTOU against a running app).
        if applyChanges { requireAppClosed() }
        let readStore = try Store(path: applyChanges ? storePath : snapshotted(storePath))
        var totalDrops = 0
        for m in try readStore.meetings(fromYMD: "2000-01-01", toYMDExclusive: "2100-01-01", limit: 10_000) {
            let tasks = try readStore.tasks(meetingID: m.id)
            let drops = TaskIntelligence.crossHalfDedupePlan(tasks)
            guard !drops.isEmpty else { continue }
            let byID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
            for d in drops {
                print("\(applyChanges ? "DROP " : "PLAN ")  [\(m.title.prefix(28))] \(byID[d]?.owner ?? "—"): \(byID[d]?.text.prefix(60) ?? "")")
            }
            if applyChanges { try readStore.deleteTasks(ids: drops) }
            totalDrops += drops.count
        }
        print("\(totalDrops) near-duplicate task\(totalDrops == 1 ? "" : "s") \(applyChanges ? "dropped" : "planned — re-run with --apply (app closed) to drop").")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("cbeval dedupe-tasks: \(error)\n".utf8)); exit(1)
    }
}

// `backfill-dates` mode (Task 2.2): plan on a snapshot; --apply writes the REAL store.
if backfillDates {
    do {
        if applyChanges {
            requireAppClosed()   // writing the live store: the app's WAL writer would race
            let store = try Store(path: storePath)
            let changes = try DateBackfill.plan(store: store)
            for c in changes { print("APPLY  \(c.oldDate) → \(c.newDate)  \(c.title.prefix(60))") }
            let n = try DateBackfill.apply(store: store, changes: changes)
            print("\(n) meeting date\(n == 1 ? "" : "s") repaired.")
        } else {
            let store = try Store(path: try snapshotted(storePath))
            let changes = try DateBackfill.plan(store: store)
            if changes.isEmpty { print("Nothing to repair — all transcribed meetings look correctly dated.") }
            for c in changes { print("PLAN   \(c.oldDate) → \(c.newDate)  \(c.title.prefix(60))") }
            print("\(changes.count) change\(changes.count == 1 ? "" : "s") planned. Re-run with --apply (app closed) to write.")
        }
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("cbeval backfill-dates: \(error)\n".utf8)); exit(1)
    }
}

// `ask` mode: one production-path question → per-stage metrics (baseline capture).
// `summarize <meetingID|title-substring>` — run the LOCAL summarizer against a real call from a
// read-only snapshot and print the result (the summaries-v2 quality iteration loop).
if let target = summarizeMeeting {
    do {
        let store = try Store(path: try snapshotted(storePath))
        let meetings = try store.recentMeetings()
        guard let m = meetings.first(where: { $0.id == target })
            ?? meetings.first(where: { $0.displayTitle.localizedCaseInsensitiveContains(target) }) else {
            FileHandle.standardError.write(Data("cbeval: no meeting matching \(target)\n".utf8)); exit(1)
        }
        // Mirror the production transcript assembly EXACTLY (AppEnvironment.generateCallSummary).
        let utts = (try? store.utterances(meetingID: m.id)) ?? []
        var text = utts.map { ($0.speaker.map { "\($0): " } ?? "") + $0.text }.joined(separator: "\n")
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text = ((try? store.transcript(meetingID: m.id)) ?? [])
                .map { ($0.speaker.map { "\($0): " } ?? "") + $0.text }.joined(separator: "\n")
        }
        guard !text.isEmpty else { FileHandle.standardError.write(Data("cbeval: no transcript\n".utf8)); exit(1) }
        print("== \(m.displayTitle) · \(m.date) · \(text.count) chars ==\n")
        let summarizer = OllamaSummarizer(
            model: UserDefaults.standard.string(forKey: "callbrain.localSummaryModel") ?? "qwen2.5:3b",
            profile: PersonalProfile.load())
        let t0 = Date()
        guard let r = await summarizer.summarize(transcript: text, title: m.displayTitle) else {
            FileHandle.standardError.write(Data("cbeval: summarizer returned nil (Ollama down?)\n".utf8)); exit(1)
        }
        print(r.summary)
        print("\n-- ACTION ITEMS (\(r.actionItems.count)) --")
        for it in r.actionItems { print("• \(it.owner ?? "Unassigned"): \(it.text)") }
        print(String(format: "\n(%.1fs, model pass)", Date().timeIntervalSince(t0)))
    } catch {
        FileHandle.standardError.write(Data("cbeval summarize failed: \(error)\n".utf8)); exit(1)
    }
    exit(0)
}

if let q = askQuestion {
    guard FileManager.default.fileExists(atPath: storePath) else {
        FileHandle.standardError.write(Data("cbeval: store not found at \(storePath)\n".utf8)); exit(1)
    }
    do {
        let store = try Store(path: try snapshotted(storePath))
        let engine = SearchEngine(store: store, embedder: OllamaEmbedder(), space: "nomic__v1")
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("cbeval-sandbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        // Mirror the production call site EXACTLY (AppEnvironment.ask) — identity + profile
        // included, or baseline answers measure a differently-configured engine.
        let ask = AskEngine(search: engine, llm: ClaudeRunner(sandboxDir: sandbox.path), model: "opus",
                            identityAliases: FounderIdentity.aliases, profile: PersonalProfile.load())
        let a: AskEngine.Answer
        if streamAsk {
            print("---- streaming ----")
            a = try await ask.ask(q, onToken: { t in
                FileHandle.standardOutput.write(Data(t.utf8))   // live tokens, unbuffered
            })
            print("\n---- stream done ----")
        } else {
            a = try await ask.ask(q)
        }
        print("status: \(a.status.rawValue)  citations: \(a.citations.count)")
        print("---- answer (first 1200 chars) ----")
        print(String(a.text.prefix(1200)))
        print("-----------------------------------")
        if let m = a.metrics {
            let ftt = m.firstTokenMS.map { " firstToken=\($0)ms" } ?? ""
            print("retrieve=\(m.retrieveMS)ms promptBuild=\(m.promptBuildMS)ms generate=\(m.generateMS)ms total=\(m.totalMS)ms\(ftt) evidence=\(m.evidenceCount) provider=\(m.provider ?? "?")")
            m.appendToLog()
        } else {
            print("no metrics (refused before retrieval?)")
        }
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("cbeval ask: \(error)\n".utf8)); exit(1)
    }
}

guard FileManager.default.fileExists(atPath: storePath) else {
    FileHandle.standardError.write(Data("cbeval: store not found at \(storePath)\n".utf8)); exit(1)
}
guard let goldData = FileManager.default.contents(atPath: goldPath) else {
    FileHandle.standardError.write(Data("cbeval: gold set not found at \(goldPath)\n".utf8)); exit(1)
}

do {
    let gold = try JSONDecoder().decode([GoldQuestion].self, from: goldData)
    let store = try Store(path: try snapshotted(storePath))
    let engine = SearchEngine(store: store, embedder: OllamaEmbedder(), space: "nomic__v1")

    let result = try await RetrievalEval.run(search: engine, gold: gold, k: k)
    if asJSON {
        struct Out: Codable { let hitAtK: Double; let k: Int; let questions: Int; let misses: [String] }
        let misses = result.perQuestion.filter { !$0.hit }.map(\.question)
        let out = Out(hitAtK: result.hitAtK, k: k, questions: result.perQuestion.count, misses: misses)
        print(String(data: try JSONEncoder().encode(out), encoding: .utf8) ?? "{}")
    } else {
        for q in result.perQuestion { print("\(q.hit ? "✓" : "✗")  \(q.question)") }
        print(String(format: "hit@%d = %.2f  (%d/%d)", k, result.hitAtK,
                     result.perQuestion.filter(\.hit).count, result.perQuestion.count))
    }
    exit(result.perQuestion.isEmpty ? 1 : 0)
} catch {
    FileHandle.standardError.write(Data("cbeval: \(error)\n".utf8)); exit(1)
}
