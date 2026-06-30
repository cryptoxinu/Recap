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
            m("g", "morning sync", "2026-06-29", "gmeet_gemini", ["Max", "Travis", "Zade", "Ghazal"]),
            m("f", "Morning Sync", "2026-06-29", "fireflies", ["Max", "Travis", "Zade"]),
            m("o", "Unrelated 1:1", "2026-06-29", "fathom", ["Noah"]),
        ]
        let s = DuplicateDetector.suggestions(metas)
        #expect(s.count == 1)
        #expect(Set([s[0].a.id, s[0].b.id]) == ["g", "f"])
        #expect(s[0].reason.contains("same call"))
    }

    @Test("different dates are never flagged")
    func differentDates() {
        let metas = [
            m("a", "standup", "2026-06-29", "fireflies", ["Max", "Travis"]),
            m("b", "standup", "2026-06-30", "fireflies", ["Max", "Travis"]),
        ]
        #expect(DuplicateDetector.suggestions(metas).isEmpty)
    }

    @Test("low overlap on the same date is not flagged")
    func lowOverlap() {
        let metas = [
            m("a", "design review", "2026-06-29", "fireflies", ["Max"]),
            m("b", "budget call", "2026-06-29", "fathom", ["Hema", "Noah", "Chris"]),
        ]
        #expect(DuplicateDetector.suggestions(metas).isEmpty)
    }

    @Test("a single shared person (two different same-day 1:1s) is NOT flagged (gate MED)")
    func singleSharedPersonNotFlagged() {
        let metas = [
            m("a", "Render pricing sync", "2026-06-29", "fireflies", ["Travis", "Zade"]),
            m("b", "Validator economics review", "2026-06-29", "fathom", ["Travis", "Max"]),  // only Travis shared
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
}
