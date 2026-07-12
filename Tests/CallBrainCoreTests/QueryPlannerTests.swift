import Testing
import Foundation
@testable import CallBrainCore

@Suite("QueryPlanner (temporal + mode planning)")
struct QueryPlannerTests {

    /// Fixed clock for determinism: 2026-06-29 12:00 in a fixed calendar (Sunday-first weeks).
    private func fixed() -> (now: Date, cal: Calendar) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        cal.firstWeekday = 1
        let now = cal.date(from: DateComponents(year: 2026, month: 6, day: 29, hour: 12))!
        return (now, cal)
    }

    @Test("today / yesterday windows")
    func todayYesterday() {
        let (now, cal) = fixed()
        let today = QueryPlanner.plan("what did we cover today", now: now, calendar: cal)
        #expect(today.dateRange?.startYMD == "2026-06-29")
        #expect(today.dateRange?.endYMDExclusive == "2026-06-30")
        #expect(today.mode == .timeScoped)

        let y = QueryPlanner.plan("what was said yesterday", now: now, calendar: cal).dateRange
        #expect(y?.startYMD == "2026-06-28")
        #expect(y?.endYMDExclusive == "2026-06-29")
    }

    @Test("'past month' is ROLLING and includes today; 'last month' is the previous calendar month (A MED)")
    func pastVsLastMonth() {
        let (now, cal) = fixed()   // 2026-06-29
        let past = QueryPlanner.plan("what happened past month", now: now, calendar: cal).dateRange!
        #expect(past.startYMD <= "2026-06-29" && "2026-06-29" < past.endYMDExclusive)  // includes TODAY
        let last = QueryPlanner.plan("what happened last month", now: now, calendar: cal).dateRange!
        #expect(last.startYMD == "2026-05-01")
        #expect(last.endYMDExclusive == "2026-06-01")   // ends before this month — excludes today
    }

    @Test("person lane catches a LOWERCASE name but not a pronoun (A HIGH)")
    func lowercasePerson() {
        #expect(QueryPlanner.personCandidate("what did riley say about pricing") == "Riley")
        #expect(QueryPlanner.personCandidate("what did Priya Kalhor mention") == "Priya Kalhor")
        #expect(QueryPlanner.personCandidate("what did we decide") == nil)   // pronoun, not a person
    }

    @Test("source-find phrasings that name a speaker mid-sentence extract that speaker (Phase-2 audit HIGH)")
    func sourceFindNamesSpeaker() {
        #expect(QueryPlanner.personCandidate("find where Dom said the pricing was wrong") == "Dom")
        #expect(QueryPlanner.personCandidate("which call did Priya mention the referral program") == "Priya")
        #expect(QueryPlanner.personCandidate("where did we land on pricing") == nil)   // pronoun
        // And end-to-end: "find where Dom said…" plans .sourceFind WITH the speaker set.
        let plan = QueryPlanner.plan("find where Dom said the pricing was wrong")
        #expect(plan.mode == .sourceFind)
        #expect(plan.speaker == "Dom")
    }

    @Test("this week / last week are adjacent 7-day windows containing/preceding today")
    func weeks() {
        let (now, cal) = fixed()
        let tw = QueryPlanner.plan("action items this week", now: now, calendar: cal).dateRange!
        // window is 7 days and contains today
        #expect(tw.startYMD <= "2026-06-29" && "2026-06-29" < tw.endYMDExclusive)
        let lw = QueryPlanner.plan("what did we decide last week", now: now, calendar: cal).dateRange!
        #expect(lw.endYMDExclusive == tw.startYMD)         // last week ends where this week starts
    }

    @Test("this month / last month")
    func months() {
        let (now, cal) = fixed()
        let tm = QueryPlanner.plan("summarize this month", now: now, calendar: cal).dateRange!
        #expect(tm.startYMD == "2026-06-01")
        #expect(tm.endYMDExclusive == "2026-07-01")
        let lm = QueryPlanner.plan("what happened last month", now: now, calendar: cal).dateRange!
        #expect(lm.startYMD == "2026-05-01")
        #expect(lm.endYMDExclusive == "2026-06-01")
    }

    @Test("rolling 'last N days' window includes today and is N days wide")
    func lastNDays() {
        let (now, cal) = fixed()
        let r = QueryPlanner.plan("what did Dom say in the last 7 days", now: now, calendar: cal).dateRange!
        #expect(r.startYMD == "2026-06-23")                // 6 days back + today = 7
        #expect(r.endYMDExclusive == "2026-06-30")
        #expect(r.label == "the last 7 days")
    }

    @Test("mode detection: action items / technical / general")
    func modes() {
        #expect(QueryPlanner.plan("what did Priya ask me to do").mode == .actionItems)
        #expect(QueryPlanner.plan("what are my action items").mode == .actionItems)
        #expect(QueryPlanner.plan("Dom specifically asked me to track what is on my plate, find that").mode == .sourceFind)
        #expect(QueryPlanner.plan("explain how validators secure the network").mode == .technical)
        #expect(QueryPlanner.plan("tell me about the Render integration").mode == .general)
    }

    @Test("source-find planning keeps the named speaker and direct-to-me signal")
    func sourceFindSpeakerAndAddressedToUser() {
        let plan = QueryPlanner.plan("Dom specifically in a call asked me to start tracking things on my plate, find that")
        #expect(plan.mode == .sourceFind)
        #expect(plan.speaker == "Dom")
        #expect(plan.addressedToUser)
    }

    @Test("explicit all-calls action question plans exhaustive named-speaker retrieval")
    func exhaustiveNamedActionQuestion() {
        let plan = QueryPlanner.plan("What was everything dom asked me todo and keep track of across all calls?")
        #expect(plan.mode == .actionItems)
        #expect(plan.speaker == "Dom")
        #expect(plan.addressedToUser)
        #expect(plan.exhaustive)
    }

    @Test("no temporal phrase → no date range")
    func noDate() {
        #expect(QueryPlanner.plan("what is the BitRouter status").dateRange == nil)
    }

    @Test("'past week' / 'past month' (no number) still date-gate (gate HIGH)")
    func pastSynonyms() {
        let (now, cal) = fixed()
        // Since Task 6.3, "past week" = the ROLLING last 7 days (not the previous calendar week).
        let pw = QueryPlanner.plan("what did we discuss in the past week about Render", now: now, calendar: cal).dateRange
        #expect(pw?.label == "the past week")
        #expect(pw != nil)                                   // date-gate NOT silently disabled
        // "past month" is now ROLLING too (audit A MED) — includes today, unlike "last month".
        let pm = QueryPlanner.plan("anything from the past month", now: now, calendar: cal).dateRange
        #expect(pm?.label == "the past month")
        #expect(pm != nil)
        #expect(pm!.startYMD <= "2026-06-29" && "2026-06-29" < pm!.endYMDExclusive)
    }
}

/// Task 6.3 — rolling past-week, absolute dates.
@Suite("QueryPlanner date upgrades (Task 6.3)")
struct QueryPlannerDateUpgradeTests {
    // Fixed "now": Thursday 2026-07-02.
    var now: Date {
        var c = DateComponents(); c.year = 2026; c.month = 7; c.day = 2; c.hour = 12
        return Calendar.current.date(from: c)!
    }

    @Test("past week is a ROLLING 7 days, not the previous calendar week")
    func testPastWeekRolling() {
        let plan = QueryPlanner.plan("what happened in my calls this past week", now: now)
        let dr = plan.dateRange
        #expect(dr?.startYMD == "2026-06-26")           // today-6
        #expect(dr?.endYMDExclusive == "2026-07-03")    // tomorrow (exclusive)
    }

    @Test("month-name absolute dates parse, current year")
    func testAbsoluteMonthName() {
        let dr = QueryPlanner.plan("what did we decide on june 25", now: now).dateRange
        #expect(dr?.startYMD == "2026-06-25")
        #expect(dr?.endYMDExclusive == "2026-06-26")
    }

    @Test("a future absolute date rolls back a year")
    func testFutureRollsBack() {
        let dr = QueryPlanner.plan("the december 15th call", now: now).dateRange
        #expect(dr?.startYMD == "2025-12-15")
    }

    @Test("numeric M/D parses")
    func testNumericDate() {
        let dr = QueryPlanner.plan("notes from 6/25", now: now).dateRange
        #expect(dr?.startYMD == "2026-06-25")
    }
}

/// Task 6.2 — person mode is finally reachable.
@Suite("Person mode (Task 6.2)")
struct PersonModeTests {
    @Test("'what did Riley say' plans person mode with the speaker")
    func testPersonDetected() {
        let plan = QueryPlanner.plan("what did Riley say about billing")
        #expect(plan.mode == .person)
        #expect(plan.speaker == "Riley")
    }
    @Test("full names + other verbs + LOWERCASE names work; pronouns/articles are NOT people (A HIGH)")
    func testVariants() {
        #expect(QueryPlanner.plan("what did Dominic Vance commit to").speaker == "Dominic Vance")
        #expect(QueryPlanner.plan("what has Priya said recently").speaker == "Priya")
        #expect(QueryPlanner.plan("what did riley say about pricing").speaker == "Riley")  // lowercase now works
        #expect(QueryPlanner.plan("what was everything Dom said").speaker == "Dom")
        #expect(QueryPlanner.plan("what all did dom say about slackbot").speaker == "Dom")
        #expect(QueryPlanner.plan("Dom specifically asked me to track the Slackbot work").speaker == "Dom")
        #expect(QueryPlanner.plan("Dom mentioned the Slackbot follow-up").speaker == "Dom")
        #expect(QueryPlanner.plan("what did they say about pricing").speaker == nil)          // pronoun
        #expect(QueryPlanner.plan("what did the team say").speaker == nil)                    // article-led
    }
}
