import Testing
import Foundation
@testable import CallBrainCore

@Suite("AIImporter.normalizeDate (canonical YYYY-MM-DD for date-gating)")
struct NormalizeDateTests {
    @Test("various model date formats normalize to YYYY-MM-DD (gate MED)")
    func formats() {
        #expect(AIImporter.normalizeDate("2026-06-29") == "2026-06-29")
        #expect(AIImporter.normalizeDate("2026/06/29") == "2026-06-29")
        #expect(AIImporter.normalizeDate("06/29/2026") == "2026-06-29")
        #expect(AIImporter.normalizeDate("6/29/26") == "2026-06-29")
        #expect(AIImporter.normalizeDate("Jun 29, 2026") == "2026-06-29")
        #expect(AIImporter.normalizeDate("2026-06-29T09:29:00Z") == "2026-06-29")  // ISO w/ time
    }
    @Test("garbage → nil (never store a non-canonical date)")
    func garbage() {
        #expect(AIImporter.normalizeDate("sometime last week") == nil)
        #expect(AIImporter.normalizeDate("13/40/2026") == nil)      // invalid month/day
        #expect(AIImporter.normalizeDate("") == nil)
    }
}
