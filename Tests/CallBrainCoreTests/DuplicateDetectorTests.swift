import Testing
import Foundation
@testable import CallBrainCore

@Suite("DuplicateDetector (near-duplicate suggestions)")
struct DuplicateDetectorTests {

    private func m(_ id: String, _ title: String, _ date: String, _ source: String, _ people: [String]) -> MeetingMeta {
        MeetingMeta(id: id, title: title, date: date, source: source, people: Set(people.map { $0.lowercased() }))
    }

    @Test("same call from two sources (same date, overlapping people) is flagged")
    func sameCallTwoSources() {
        let metas = [
            m("g", "morning sync", "2026-06-29", "gmeet_gemini", ["Dom", "Riley", "Alex", "Priya"]),
            m("f", "Morning Sync", "2026-06-29", "fireflies", ["Dom", "Riley", "Alex"]),
            m("o", "Unrelated 1:1", "2026-06-29", "fathom", ["Noah"]),
        ]
        let s = DuplicateDetector.suggestions(metas)
        #expect(s.count == 1)
        #expect(Set([s[0].a.id, s[0].b.id]) == ["g", "f"])
        #expect(s[0].reason.contains("same call"))
    }

    @Test("same call across sources still flagged when one tool uses full names, the other first names")
    func crossSourceNameFormats() {
        // Google records full names; Fathom logs first names of the SAME call → must still match.
        let metas = [
            m("g", "Standup", "2026-06-29", "gmeet_gemini", ["Dominic Vance", "Riley Novak", "Alex King"]),
            m("f", "standup", "2026-06-29", "fathom", ["Dom", "Riley", "Alex"]),   // wait: Dom≠Dominic first-token
        ]
        // first-name tokens: {dominic,riley,alex} vs {dom,riley,alex} → riley+alex shared (2) → flagged cross-source
        let s = DuplicateDetector.suggestions(metas)
        #expect(s.count == 1 && Set([s[0].a.id, s[0].b.id]) == ["g", "f"])
    }

    @Test("firstNames normalizes to the first token, lowercased")
    func firstNames() {
        #expect(DuplicateDetector.firstNames(["Alex King", "Riley Novak"]) == ["alex", "riley"])
    }

    @Test("different dates are never flagged")
    func differentDates() {
        let metas = [
            m("a", "standup", "2026-06-29", "fireflies", ["Dom", "Riley"]),
            m("b", "standup", "2026-06-30", "fireflies", ["Dom", "Riley"]),
        ]
        #expect(DuplicateDetector.suggestions(metas).isEmpty)
    }

    @Test("low overlap on the same date is not flagged")
    func lowOverlap() {
        let metas = [
            m("a", "design review", "2026-06-29", "fireflies", ["Dom"]),
            m("b", "budget call", "2026-06-29", "fathom", ["Nadia", "Noah", "Chris"]),
        ]
        #expect(DuplicateDetector.suggestions(metas).isEmpty)
    }

    @Test("a single shared person (two different same-day 1:1s) is NOT flagged (gate MED)")
    func singleSharedPersonNotFlagged() {
        let metas = [
            m("a", "Render pricing sync", "2026-06-29", "fireflies", ["Riley", "Alex"]),
            m("b", "Validator economics review", "2026-06-29", "fathom", ["Riley", "Dom"]),  // only Riley shared
        ]
        // shared = 1 (< 2) → not strong-people; titles distinct → not flagged
        #expect(DuplicateDetector.suggestions(metas).isEmpty)
    }

    @Test("two same-day generic 'Untitled meeting' imports are NOT flagged on title (gate MED)")
    func genericTitlesNotFlagged() {
        let metas = [
            m("a", "Untitled meeting", "2026-06-29", "paste", []),
            m("b", "Untitled meeting", "2026-06-29", "paste", []),
        ]
        #expect(DuplicateDetector.suggestions(metas).isEmpty)
    }

    @Test("suggestion id is order-independent (gate LOW)")
    func orderIndependentID() {
        let s1 = DuplicateSuggestion(a: m("a", "x", "d", "s", []), b: m("b", "x", "d", "s", []), score: 1, reason: "")
        let s2 = DuplicateSuggestion(a: m("b", "x", "d", "s", []), b: m("a", "x", "d", "s", []), score: 1, reason: "")
        #expect(s1.id == s2.id)
    }

    @Test("jaccard + titleJaccard math")
    func math() {
        #expect(DuplicateDetector.jaccard(Set(["a", "b"]), Set(["a", "b"])) == 1.0)
        #expect(DuplicateDetector.jaccard(Set(["a", "b"]), Set(["a", "c"])) == 1.0 / 3.0)
        #expect(DuplicateDetector.titleJaccard("Weekly sync call", "weekly sync") > 0.5)
    }

    private func mSmart(_ id: String, _ title: String, _ smart: String?, _ date: String, _ source: String, _ people: [String]) -> MeetingMeta {
        MeetingMeta(id: id, title: title, smartTitle: smart, date: date, source: source, people: Set(people.map { $0.lowercased() }))
    }

    @Test("FOUNDER BUG: two different same-source calls (date-stamp titles, shared team) are NOT flagged")
    func dateStampSameSourceNotFlagged() {
        // Two distinct Ambient standups the same day, same recurring team, both auto-named after a timestamp,
        // each with its OWN meaningful AI title. Must not be paired (the screenshot's false "100% match").
        let metas = [
            mSmart("a", "Meeting started 2026-06-24 10-09 PDT", "Ambient Network Architecture Review",
                   "2026-06-24", "gmeet_gemini", ["Dom", "Riley", "Alex", "Marco"]),
            mSmart("b", "Meeting started 2026-06-24 12-32 PDT", "Render Integration & Pearl Risk Review",
                   "2026-06-24", "gmeet_gemini", ["Dom", "Riley", "Alex", "Marco"]),
        ]
        #expect(DuplicateDetector.suggestions(metas).isEmpty)
    }

    @Test("date-stamp titles with NO smart title are treated as generic (not title-matched)")
    func dateStampNoSmartTitleNotFlagged() {
        let metas = [
            m("a", "Meeting started 2026-06-24 10-09 PDT", "2026-06-24", "gmeet_gemini", ["Dom", "Alex"]),
            m("b", "Meeting started 2026-06-24 12-32 PDT", "2026-06-24", "gmeet_gemini", ["Dom", "Alex"]),
        ]
        #expect(DuplicateDetector.isGenericTitle("Meeting started 2026-06-24 12-32 PDT"))
        #expect(DuplicateDetector.suggestions(metas).isEmpty)
    }

    @Test("isGenericTitle: date-stamp auto-titles are generic, but a real title with a date is NOT")
    func genericTitleScoping() {
        #expect(DuplicateDetector.isGenericTitle("Meeting started 2026-06-24 12-32 PDT"))
        #expect(DuplicateDetector.isGenericTitle("2026-06-24"))
        #expect(DuplicateDetector.isGenericTitle("Untitled meeting"))
        #expect(!DuplicateDetector.isGenericTitle("Q3 Board Review 2026-06-24"))   // real subject + a date
        #expect(!DuplicateDetector.isGenericTitle("Render Integration Review"))
    }

    @Test("matching uses the SMART title: identical smart titles across sources DO flag")
    func smartTitleMatches() {
        let metas = [
            mSmart("a", "Meeting started 2026-06-24 10-09 PDT", "Render Integration Review",
                   "2026-06-24", "gmeet_gemini", ["Dom"]),
            mSmart("b", "Recording 1", "Render Integration Review",
                   "2026-06-24", "fathom", ["Riley"]),
        ]
        let s = DuplicateDetector.suggestions(metas)
        #expect(s.count == 1)
        #expect(s[0].a.displayTitle == "Render Integration Review")
    }
}
