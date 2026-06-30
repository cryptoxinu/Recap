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
        let r = QueryPlanner.plan("what did Max say in the last 7 days", now: now, calendar: cal).dateRange!
        #expect(r.startYMD == "2026-06-23")                // 6 days back + today = 7
        #expect(r.endYMDExclusive == "2026-06-30")
        #expect(r.label == "the last 7 days")
    }

    @Test("mode detection: action items / technical / general")
    func modes() {
        #expect(QueryPlanner.plan("what did Ghazal ask me to do").mode == .actionItems)
        #expect(QueryPlanner.plan("what are my action items").mode == .actionItems)
        #expect(QueryPlanner.plan("explain how validators secure the network").mode == .technical)
        #expect(QueryPlanner.plan("tell me about the Render integration").mode == .general)
    }

    @Test("no temporal phrase → no date range")
    func noDate() {
        #expect(QueryPlanner.plan("what is the BitRouter status").dateRange == nil)
    }

    @Test("'past week' / 'past month' (no number) parse as last week/month (gate HIGH)")
    func pastSynonyms() {
        let (now, cal) = fixed()
        let pw = QueryPlanner.plan("what did we discuss in the past week about Render", now: now, calendar: cal).dateRange
        #expect(pw?.label == "last week")
        #expect(pw != nil)                                   // date-gate NOT silently disabled
        let pm = QueryPlanner.plan("anything from the past month", now: now, calendar: cal).dateRange
        #expect(pm?.label == "last month")
    }
}
