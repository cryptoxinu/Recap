import Testing
import Foundation
@testable import CallBrainCore

/// Live-recording durability (v18) — the pending-link table + note idempotency + merge carry-over
/// that replaced the fragile in-memory 60s poll (P1 audit HIGH/MED remediation). These lock the
/// data-loss surfaces: a recording's notes + calendar link must survive a slow transcription, an
/// app relaunch, a duplicate-merge, and a retried reconcile.
@Suite("Recording link durability (v18)")
struct RecordingLinkStoreTests {

    private func freshStore() throws -> Store {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("cb-reclink-\(UUID().uuidString).sqlite").path
        return try Store(path: path)
    }

    @Test("pending link round-trips; resolves to the meeting once the import job lands one")
    func pendingRoundTrip() throws {
        let store = try freshStore()
        let wav = "/tmp/callbrain/Morning sync — 2026-07-04 0900.wav"
        try store.savePendingRecordingLink(filePath: wav, eventID: "eventKit|E1", notes: "ship the deck")

        let pending = try store.pendingRecordingLinks()
        #expect(pending.count == 1)
        #expect(pending.first?.filePath == wav)
        #expect(pending.first?.eventID == "eventKit|E1")
        #expect(pending.first?.notes == "ship the deck")

        // No job yet → unresolved.
        #expect(try store.meetingIDForImportPayload(wav) == nil)
        // The transcription job lands, carrying the meeting id on the SAME payload path.
        try store.upsertImportJob(ImportJob(id: "j1", sourceName: "rec", state: .done,
                                            meetingID: "m-rec", createdAt: 10,
                                            payloadKind: .file, payload: wav))
        #expect(try store.meetingIDForImportPayload(wav) == "m-rec")

        try store.deletePendingRecordingLink(filePath: wav)
        #expect(try store.pendingRecordingLinks().isEmpty)
    }

    @Test("a job without a meeting id (still queued) does not resolve")
    func unresolvedWhileQueued() throws {
        let store = try freshStore()
        let wav = "/tmp/rec.wav"
        try store.upsertImportJob(ImportJob(id: "j", sourceName: "rec", state: .queued,
                                            createdAt: 1, payloadKind: .file, payload: wav))
        #expect(try store.meetingIDForImportPayload(wav) == nil)
    }

    @Test("same-path re-import: the NEWEST job wins, and stays nil until IT resolves")
    func newestJobWins() throws {
        let store = try freshStore()
        let wav = "/tmp/rec.wav"
        // Old resolved job for this path…
        try store.upsertImportJob(ImportJob(id: "old", sourceName: "rec", state: .done,
                                            meetingID: "m-old", createdAt: 100,
                                            payloadKind: .file, payload: wav))
        // …then a fresh re-import of the SAME path, not yet ingested.
        try store.upsertImportJob(ImportJob(id: "new", sourceName: "rec", state: .queued,
                                            createdAt: 200, payloadKind: .file, payload: wav))
        // Must NOT bind to the stale old meeting — wait for the new job to resolve.
        #expect(try store.meetingIDForImportPayload(wav) == nil)
        try store.upsertImportJob(ImportJob(id: "new", sourceName: "rec", state: .done,
                                            meetingID: "m-new", createdAt: 200,
                                            payloadKind: .file, payload: wav))
        #expect(try store.meetingIDForImportPayload(wav) == "m-new")
    }

    @Test("save replaces in place (same path enqueued twice → one row, latest wins)")
    func saveReplaces() throws {
        let store = try freshStore()
        let wav = "/tmp/rec.wav"
        try store.savePendingRecordingLink(filePath: wav, eventID: nil, notes: "first")
        try store.savePendingRecordingLink(filePath: wav, eventID: "eventKit|E2", notes: "second")
        let pending = try store.pendingRecordingLinks()
        #expect(pending.count == 1)
        #expect(pending.first?.eventID == "eventKit|E2")
        #expect(pending.first?.notes == "second")
    }

    @Test("empty event/notes persist as nil, not empty strings")
    func emptyBecomesNil() throws {
        let store = try freshStore()
        try store.savePendingRecordingLink(filePath: "/tmp/a.wav", eventID: "", notes: "   ")
        let p = try store.pendingRecordingLinks().first
        #expect(p?.eventID == nil)
        #expect(p?.notes == nil)
    }

    @Test("appendMeetingNote is idempotent — the same note block never doubles")
    func noteIdempotent() throws {
        let store = try freshStore()
        try store.saveMeeting(Meeting(id: "m1", title: "call", date: "2026-07-04", source: .fathom), chunks: [])
        try store.appendMeetingNote(meetingID: "m1", note: "point A")
        try store.appendMeetingNote(meetingID: "m1", note: "point A")   // retried reconcile
        #expect(try store.userNotes(meetingID: "m1") == "point A")
        try store.appendMeetingNote(meetingID: "m1", note: "point B")   // a genuinely new block appends
        #expect(try store.userNotes(meetingID: "m1") == "point A\n\npoint B")
    }

    @Test("self-merge (same id) is a safe no-op — never deletes the meeting (E CRITICAL)")
    func selfMergeIsNoOp() throws {
        let store = try freshStore()
        try store.saveMeeting(Meeting(id: "m1", title: "call", date: "2026-07-04", source: .fathom), chunks: [])
        let stats = try store.mergeMeetings(loserID: "m1", survivorID: "m1")
        #expect(stats == Store.MergeStats())          // no work done
        #expect(try store.meeting(id: "m1") != nil)    // STILL THERE (not cascaded to oblivion)
    }

    @Test("merge re-points event_links to the survivor — a recording link is never lost (E HIGH)")
    func mergeKeepsEventLink() throws {
        let store = try freshStore()
        try store.saveMeeting(Meeting(id: "surv", title: "transcript", date: "2026-07-04", source: .fireflies), chunks: [])
        try store.saveMeeting(Meeting(id: "lose", title: "notes", date: "2026-07-04", source: .gmeetGemini), chunks: [])
        try store.saveEventLinks([EventMeetingLinker.Link(
            eventID: "eventKit|E1", meetingID: "lose", confidence: 1, method: "recording",
            eventTitle: "Sync", eventStart: Date())])
        try store.mergeMeetings(loserID: "lose", survivorID: "surv")
        #expect(try store.eventLinks(eventIDs: ["eventKit|E1"])["eventKit|E1"]?.meetingID == "surv")
    }

    @Test("merge: a DONE loser task wins over an open survivor duplicate (E HIGH)")
    func mergeTaskDoneWins() throws {
        let store = try freshStore()
        try store.saveMeeting(Meeting(id: "surv", title: "t", date: "2026-07-04", source: .fireflies), chunks: [],
                              tasks: [Store.TaskInput(id: "t1", owner: "Alex", text: "ship it", dedupeKey: "k")])
        try store.saveMeeting(Meeting(id: "lose", title: "n", date: "2026-07-04", source: .gmeetGemini), chunks: [],
                              tasks: [Store.TaskInput(id: "t2", owner: "Alex", text: "ship it", dedupeKey: "k")])
        _ = try store.setTaskStatus(id: "t2", .done)          // loser copy already completed
        try store.mergeMeetings(loserID: "lose", survivorID: "surv")
        let survTasks = try store.tasks(meetingID: "surv")
        #expect(survTasks.count == 1)                          // deduped
        #expect(survTasks.first?.status == .done)              // completion preserved, not resurfaced
    }

    @Test("pending link upsert COALESCES — link-then-notes keeps both (E MED)")
    func pendingLinkCoalesces() throws {
        let store = try freshStore()
        let wav = "/tmp/rec.wav"
        try store.savePendingRecordingLink(filePath: wav, eventID: "eventKit|E1", notes: nil)   // link only
        try store.savePendingRecordingLink(filePath: wav, eventID: nil, notes: "my notes")      // notes only
        let p = try store.pendingRecordingLinks().first
        #expect(p?.eventID == "eventKit|E1")   // NOT wiped by the second call
        #expect(p?.notes == "my notes")
    }

    // ── P2a: real recording start time carried to the meeting ──

    @Test("pending link round-trips a recording's start time (v20)")
    func startedAtRoundTrips() throws {
        let store = try freshStore()
        let wav = "/tmp/rec.wav"
        let began = Date(timeIntervalSince1970: 1_800_000_030)   // whole second (ISO round-trips to seconds)
        try store.savePendingRecordingLink(filePath: wav, eventID: nil, notes: nil, startedAt: began)
        let p = try store.pendingRecordingLinks().first
        #expect(p?.startedAt == began)
    }

    @Test("COALESCE preserves a stored start time across a later notes-only update")
    func startedAtCoalesces() throws {
        let store = try freshStore()
        let wav = "/tmp/rec.wav"
        let began = Date(timeIntervalSince1970: 1_800_000_030)
        try store.savePendingRecordingLink(filePath: wav, eventID: nil, notes: nil, startedAt: began)   // start only
        try store.savePendingRecordingLink(filePath: wav, eventID: "eventKit|E1", notes: "n")           // no start
        let p = try store.pendingRecordingLinks().first
        #expect(p?.startedAt == began)          // NOT wiped
        #expect(p?.eventID == "eventKit|E1")
    }

    @Test("setMeetingStartTimeIfUnset stamps a NULL start_time and never overwrites a set one")
    func setStartTimeIfUnset() throws {
        let store = try freshStore()
        // A recording lands with a NULL start_time (like TranscriptionPipeline's startedAt:nil).
        try store.saveMeeting(Meeting(id: "m1", title: "call", date: "2027-01-15", source: .gmeetLocal), chunks: [])
        func candidateStart() throws -> Date? {
            try store.meetingCandidatesForLinking().first { $0.meetingID == "m1" }?.startedAt
        }
        #expect(try candidateStart() == nil)

        let began = Date(timeIntervalSince1970: 1_800_000_030)
        try store.setMeetingStartTimeIfUnset(meetingID: "m1", startedAt: began)
        #expect(try candidateStart() == began)          // stamped

        // A second, different time must be ignored — the meeting already has a real start.
        try store.setMeetingStartTimeIfUnset(meetingID: "m1", startedAt: began.addingTimeInterval(3600))
        #expect(try candidateStart() == began)          // unchanged
    }

    @Test("saveMeeting refuses a DIFFERENT meeting with the same content_hash — closes the dedupe race (D4/E)")
    func duplicateContentRefused() throws {
        let store = try freshStore()
        try store.saveMeeting(Meeting(id: "m1", title: "call", date: "2026-07-04", source: .fathom,
                                      contentFingerprint: "sha256:abc"), chunks: [])
        // Re-saving the SAME id with the same hash is fine (id-upsert).
        try store.saveMeeting(Meeting(id: "m1", title: "call v2", date: "2026-07-04", source: .fathom,
                                      contentFingerprint: "sha256:abc"), chunks: [])
        // A DIFFERENT id with the SAME content → refused, pointing at the existing twin.
        #expect(throws: StoreError.duplicateContent(existingID: "m1")) {
            try store.saveMeeting(Meeting(id: "m2", title: "dup", date: "2026-07-04", source: .fathom,
                                          contentFingerprint: "sha256:abc"), chunks: [])
        }
    }

    @Test("merge carries the loser's live notes onto the survivor (never dropped), de-duped")
    func mergeCarriesNotes() throws {
        let store = try freshStore()
        try store.saveMeeting(Meeting(id: "survivor", title: "transcript half", date: "2026-07-04", source: .fireflies), chunks: [])
        try store.saveMeeting(Meeting(id: "loser", title: "notes half", date: "2026-07-04", source: .gmeetGemini), chunks: [])
        try store.appendMeetingNote(meetingID: "survivor", note: "shared")
        try store.appendMeetingNote(meetingID: "loser", note: "shared")        // dup — must not double
        try store.appendMeetingNote(meetingID: "loser", note: "loser-only")    // unique — must survive

        try store.mergeMeetings(loserID: "loser", survivorID: "survivor")
        #expect(try store.meeting(id: "loser") == nil)                          // gone
        #expect(try store.userNotes(meetingID: "survivor") == "shared\n\nloser-only")
    }
}
