import Testing
import Foundation
@testable import CallBrainCore

/// Calendar v4 — the deterministic prep-context assembler. Pure over injected candidates
/// (like EventMeetingLinker), so no live Store.
@Suite("Call prep assembler (v4)")
struct CallPrepTests {

    private func date(_ ymd: String) -> Date {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"; df.locale = Locale(identifier: "en_US_POSIX")
        return df.date(from: ymd)!
    }

    private func cand(_ id: String, _ title: String, _ ymd: String, people: [String] = [],
                      tasks: [(String?, String)] = [], resolved: [(String?, String)] = [],
                      oneLiner: String? = nil, summary: String? = nil,
                      semantic: Double? = nil) -> CallPrep.Candidate {
        CallPrep.Candidate(meetingID: id, title: title, date: ymd, oneLiner: oneLiner,
                           summary: summary, people: people, openTasks: tasks, resolvedTasks: resolved,
                           semanticScore: semantic)
    }

    @Test("same-series title match links prior calls even with no shared attendee list")
    func testSeriesMatch() {
        let ctx = CallPrep.assemble(
            eventTitle: "Ambient Morning Sync", start: date("2026-07-06"), attendees: [],
            candidates: [cand("m1", "Ambient Morning Sync", "2026-07-02"),
                         cand("m2", "Dentist", "2026-07-01")])
        #expect(ctx.priorMeetings.map(\.meetingID) == ["m1"])
        #expect(ctx.hasContent)
    }

    @Test("attendee overlap links a differently-titled call")
    func testAttendeeMatch() {
        let ctx = CallPrep.assemble(
            eventTitle: "1:1", start: date("2026-07-06"), attendees: ["Riley Novak", "Alex"],
            candidates: [cand("m1", "Billing Deep-Dive", "2026-07-02", people: ["Riley Novak", "Priya"])])
        #expect(ctx.priorMeetings.map(\.meetingID) == ["m1"])
    }

    @Test("a strong SEMANTIC match qualifies a call with no shared title tokens or attendees (prep FIX 6)")
    func testSemanticMatchQualifies() {
        let ctx = CallPrep.assemble(
            eventTitle: "Fundraising strategy", start: date("2026-07-06"), attendees: ["Dana"],
            candidates: [
                cand("m1", "Random unrelated call", "2026-07-02", people: ["Someone"], semantic: 0.72),
                cand("m2", "Dentist appointment", "2026-07-01", people: ["Nobody"], semantic: 0.20),
            ])
        // m1 (strong semantic) is included despite no title/attendee overlap; m2 (weak) is not.
        #expect(ctx.priorMeetings.map(\.meetingID) == ["m1"])
    }

    @Test("a lexical (title/attendee) match still outranks a pure semantic match (prep FIX 6)")
    func testLexicalOutranksSemantic() {
        let ctx = CallPrep.assemble(
            eventTitle: "Morning Sync", start: date("2026-07-06"), attendees: ["Alice"],
            candidates: [
                cand("sem", "Totally different title", "2026-07-02", people: ["Zed"], semantic: 0.9),
                cand("lex", "Morning Sync", "2026-07-03", people: ["Alice"]),   // title + attendee match
            ])
        #expect(ctx.priorMeetings.first?.meetingID == "lex")   // lexical match ranks first
        #expect(Set(ctx.priorMeetings.map(\.meetingID)) == ["lex", "sem"])   // both included
    }

    @Test("a call with neither title nor attendee overlap is excluded")
    func testExcludesUnrelated() {
        let ctx = CallPrep.assemble(
            eventTitle: "Render Partnership", start: date("2026-07-06"), attendees: ["Nate"],
            candidates: [cand("m1", "Dentist", "2026-07-02", people: ["Dr. Weisz"])])
        #expect(ctx.priorMeetings.isEmpty)
        #expect(!ctx.hasContent)
    }

    @Test("ranking: same-series + shared attendee outranks title-only, newest breaks ties, cap 5")
    func testRankingAndCap() {
        var cands: [CallPrep.Candidate] = []
        for i in 0..<8 { cands.append(cand("m\(i)", "Ambient Morning Sync", "2026-06-2\(i % 10)")) }
        cands.append(cand("best", "Ambient Morning Sync", "2026-06-15", people: ["Riley"]))
        let ctx = CallPrep.assemble(
            eventTitle: "Ambient Morning Sync", start: date("2026-07-06"),
            attendees: ["Riley Novak"], candidates: cands)
        #expect(ctx.priorMeetings.count == 5)
        #expect(ctx.priorMeetings.first?.meetingID == "best")   // title + attendee wins
    }

    @Test("open commitments gather across chosen calls, deduped by text")
    func testCommitments() {
        let ctx = CallPrep.assemble(
            eventTitle: "Morning Sync", start: date("2026-07-06"), attendees: [],
            candidates: [cand("m1", "Morning Sync", "2026-07-02", people: ["Alex"],
                              tasks: [("Alex", "send the deck"), (nil, "book the room")]),
                         cand("m2", "Morning Sync", "2026-07-01", people: ["Alex"],
                              tasks: [("Alex", "send the deck")])])   // dup text
        #expect(ctx.openCommitments.map(\.text) == ["send the deck", "book the room"])
        #expect(ctx.openCommitments.first?.owner == "Alex")   // Alex is on the call → owner grounded/kept
    }

    @Test("recurring topics come from shared CONTENT across ≥2 calls (one-liners), not titles (prep-audit HIGH)")
    func testRecurringTopics() {
        let ctx = CallPrep.assemble(
            eventTitle: "GLM Scaling Review", start: date("2026-07-06"), attendees: ["Chris"],
            candidates: [cand("m1", "GLM Scaling Review", "2026-07-02", people: ["Chris"],
                              oneLiner: "Discussed GLM scaling and verification thresholds."),
                         cand("m2", "GLM Scaling Deep-Dive", "2026-07-01", people: ["Chris"],
                              oneLiner: "More on GLM scaling; also pricing.")])
        #expect(ctx.priorMeetings.count == 2)
        #expect(ctx.recurringTopics.contains("Glm"))        // in BOTH one-liners
        #expect(ctx.recurringTopics.contains("Scaling"))    // in BOTH one-liners
        #expect(!ctx.recurringTopics.contains("Pricing"))   // only one call → not recurring
    }

    @Test("'Where you left off' names the most RECENT prior call, not the highest-ranked (final-audit LOW)")
    func testWhereLeftOffRecency() {
        // Older call has a shared attendee (ranks higher); newer call has none — the recap
        // line must still name the newer call.
        let ctx = CallPrep.assemble(
            eventTitle: "Morning Sync", start: date("2026-07-10"), attendees: ["Sam"],
            candidates: [cand("old", "Morning Sync", "2026-06-01", people: ["Sam"], oneLiner: "old"),
                         cand("new", "Morning Sync", "2026-07-05", oneLiner: "newest")])
        // 'new' matched by title series; 'old' by title+attendee (higher score).
        #expect(ctx.priorMeetings.first?.meetingID == "old")     // ranking still puts old first
        let brief = PrepPrompt.deterministicBrief(ctx)
        #expect(brief.contains("2026-07-05"))                    // but recap names the newer call
        #expect(!brief.contains("Where you left off — Morning Sync (2026-06-01)"))
    }

    @Test("deterministicBrief renders free context; empty context says first-call")
    func testDeterministicBrief() {
        let empty = CallPrep.assemble(eventTitle: "New Thing", start: date("2026-07-06"),
                                      attendees: [], candidates: [])
        #expect(PrepPrompt.deterministicBrief(empty).contains("first call"))

        let ctx = CallPrep.assemble(
            eventTitle: "Morning Sync", start: date("2026-07-06"), attendees: [],
            candidates: [cand("m1", "Morning Sync", "2026-07-02", tasks: [("Alex", "send the deck")],
                             oneLiner: "Talked scaling.")])
        let brief = PrepPrompt.deterministicBrief(ctx)
        #expect(brief.contains("Where you left off"))
        #expect(brief.contains("send the deck"))
    }

    @Test("same task text owned by two people stays two commitments (audit MED)")
    func testCommitmentOwnerDedup() {
        let ctx = CallPrep.assemble(
            eventTitle: "Morning Sync", start: date("2026-07-06"), attendees: [],
            candidates: [cand("m1", "Morning Sync", "2026-07-02", people: ["Alice", "Bob"],
                              tasks: [("Alice", "send the deck"), ("Bob", "send the deck")])])
        #expect(ctx.openCommitments.count == 2)
        #expect(Set(ctx.openCommitments.map(\.owner)) == ["Alice", "Bob"])
    }

    @Test("a commitment owner NOT on the call is shown unattributed, not mis-attributed (prep-audit HIGH)")
    func testUngroundedOwnerNulled() {
        let ctx = CallPrep.assemble(
            eventTitle: "Morning Sync", start: date("2026-07-06"), attendees: [],
            candidates: [cand("m1", "Morning Sync", "2026-07-02", people: ["Chris"],
                              tasks: [("Chris", "ship the fix"), ("Randoperson", "do a thing")])])
        #expect(ctx.openCommitments.first { $0.text == "ship the fix" }?.owner == "Chris")  // on-call → kept
        let doThing = ctx.openCommitments.first { $0.text == "do a thing" }
        #expect(doThing != nil)            // the task is still surfaced…
        #expect(doThing?.owner == nil)     // …but unattributed (owner isn't a participant)
    }

    @Test("a commitment resolved (done) in another chosen call is suppressed (prep-audit HIGH)")
    func testResolvedSuppressed() {
        let ctx = CallPrep.assemble(
            eventTitle: "Morning Sync", start: date("2026-07-06"), attendees: [],
            candidates: [cand("m1", "Morning Sync", "2026-07-02", people: ["Chris"],
                              tasks: [("Chris", "ship the fix"), ("Chris", "still open")]),
                         cand("m2", "Morning Sync", "2026-07-05", people: ["Chris"],
                              resolved: [(nil, "ship the fix")])])   // done in a LATER call
        #expect(!ctx.openCommitments.contains { $0.text == "ship the fix" })   // suppressed
        #expect(ctx.openCommitments.contains { $0.text == "still open" })      // kept
    }

    @Test("a done task from one person does NOT suppress a same-text open task owned by another (Codex HIGH)")
    func testResolutionIsOwnerCompatible() {
        let ctx = CallPrep.assemble(
            eventTitle: "Morning Sync", start: date("2026-07-06"), attendees: [],
            candidates: [cand("m1", "Morning Sync", "2026-07-02", people: ["Alice", "Bob"],
                              tasks: [("Bob", "send the deck")]),
                         cand("m2", "Morning Sync", "2026-07-05", people: ["Alice", "Bob"],
                              resolved: [("Alice", "send the deck")])])   // ALICE finished HERS
        // Bob's identical-text commitment is a different person's task → must survive.
        #expect(ctx.openCommitments.contains { $0.text == "send the deck" && $0.owner == "Bob" })
    }

    @Test("an OLDER done task does not cancel a NEWER recurrence of the same open task (Codex HIGH)")
    func testResolutionRespectsChronology() {
        let ctx = CallPrep.assemble(
            eventTitle: "Morning Sync", start: date("2026-07-06"), attendees: [],
            candidates: [cand("m1", "Morning Sync", "2026-07-05", people: ["Chris"],
                              tasks: [("Chris", "review the doc")]),        // open on the NEWER call
                         cand("m2", "Morning Sync", "2026-07-02",
                              resolved: [(nil, "review the doc")])])          // done on an OLDER call
        #expect(ctx.openCommitments.contains { $0.text == "review the doc" })  // newer open kept
    }

    @Test("owners survive when a call has NO extracted people to ground against (Codex HIGH)")
    func testOwnerKeptWhenNoPeopleToGround() {
        let ctx = CallPrep.assemble(
            eventTitle: "Morning Sync", start: date("2026-07-06"), attendees: [],
            candidates: [cand("m1", "Morning Sync", "2026-07-02", people: [],   // nothing to ground
                              tasks: [("Dana", "book the venue")])])
        // With no people set we can't verify OR refute Dana → keep the attribution rather than nuke it.
        #expect(ctx.openCommitments.first { $0.text == "book the venue" }?.owner == "Dana")
    }

    @Test("a single shared attendee on a big-group event does NOT qualify an unrelated call (prep-audit HIGH)")
    func testOverMatchGate() {
        let ctx = CallPrep.assemble(
            eventTitle: "Board Meeting", start: date("2026-07-06"),
            attendees: ["Alice", "Bob", "Chris", "Dana"],
            candidates: [cand("m1", "Dentist Appointment", "2026-07-02", people: ["Alice"])])
        #expect(ctx.priorMeetings.isEmpty)   // 1/4 attendees + no title overlap → not relevant
    }

    @Test("recurring topics require overlap with the EVENT title (audit LOW)")
    func testTopicsGatedByEventTitle() {
        // Two attendee-matched calls both titled "Weekly Review" — but the upcoming event is
        // "Pricing Chat", so "Review" must NOT surface as a topic.
        let ctx = CallPrep.assemble(
            eventTitle: "Pricing Chat", start: date("2026-07-06"), attendees: ["Sam"],
            candidates: [cand("m1", "Weekly Review", "2026-07-02", people: ["Sam"]),
                         cand("m2", "Weekly Review", "2026-07-01", people: ["Sam"])])
        #expect(ctx.priorMeetings.count == 2)           // still linked (attendee)
        #expect(!ctx.recurringTopics.contains("Review"))
    }

    @Test("a single shared token in short titles is NOT the same series without attendee support (audit LOW)")
    func testSingleTokenNotSeries() {
        // "Pricing Chat" vs "Pricing Review" share only "pricing"; no shared attendee → excluded.
        let ctx = CallPrep.assemble(
            eventTitle: "Pricing Chat", start: date("2026-07-06"), attendees: [],
            candidates: [cand("m1", "Pricing Review", "2026-07-02")])
        #expect(ctx.priorMeetings.isEmpty)
    }

    @Test("source hash changes when the event is rescheduled or attendees change (audit HIGH)")
    func testSourceHashInputs() {
        let base = CallPrep.assemble(eventTitle: "Sync Standup", start: date("2026-07-06"),
            attendees: ["Sam"], candidates: [cand("m1", "Sync Standup", "2026-07-02", people: ["Sam"])])
        let rescheduled = CallPrep.assemble(eventTitle: "Sync Standup", start: date("2026-07-07"),
            attendees: ["Sam"], candidates: [cand("m1", "Sync Standup", "2026-07-02", people: ["Sam"])])
        let attendeesChanged = CallPrep.assemble(eventTitle: "Sync Standup", start: date("2026-07-06"),
            attendees: ["Sam", "Alex"], candidates: [cand("m1", "Sync Standup", "2026-07-02", people: ["Sam"])])
        #expect(PrepPrompt.sourceHash(base) != PrepPrompt.sourceHash(rescheduled))
        #expect(PrepPrompt.sourceHash(base) != PrepPrompt.sourceHash(attendeesChanged))
    }

    @Test("source hash is deterministic and changes when a summary changes")
    func testSourceHash() {
        let a = CallPrep.assemble(eventTitle: "Billing Review", start: date("2026-07-06"), attendees: [],
            candidates: [cand("m1", "Billing Review", "2026-07-02", summary: "v1")])
        let a2 = CallPrep.assemble(eventTitle: "Billing Review", start: date("2026-07-06"), attendees: [],
            candidates: [cand("m1", "Billing Review", "2026-07-02", summary: "v1")])
        let b = CallPrep.assemble(eventTitle: "Billing Review", start: date("2026-07-06"), attendees: [],
            candidates: [cand("m1", "Billing Review", "2026-07-02", summary: "v2")])
        #expect(a.hasContent)   // guards against a degenerate all-stopword title matching nothing
        #expect(PrepPrompt.sourceHash(a) == PrepPrompt.sourceHash(a2))
        #expect(PrepPrompt.sourceHash(a) != PrepPrompt.sourceHash(b))
    }

    @Test("prep query names the event + people and varies by template")
    func testQueryTemplates() {
        let ctx = CallPrep.assemble(
            eventTitle: "Ambient Morning Sync", start: date("2026-07-06"),
            attendees: ["Riley Novak"], candidates: [cand("m1", "Ambient Morning Sync", "2026-07-02")])
        let brief = PrepPrompt.query(context: ctx, template: .brief)
        #expect(brief.contains("Ambient Morning Sync"))
        #expect(brief.contains("Riley Novak"))
        #expect(brief.contains("talking points"))
        let tp = PrepPrompt.query(context: ctx, template: .talkingPoints)
        #expect(tp.contains("talking points"))
        #expect(PrepPrompt.query(context: ctx, template: .decisionsRecap).contains("decisions"))
    }
}
