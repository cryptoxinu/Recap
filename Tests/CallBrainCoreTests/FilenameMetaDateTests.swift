import Testing
import Foundation
@testable import CallBrainCore

/// Perfection plan Task 2.1 — every transcribed recording was stamped with the IMPORT date
/// because runTranscription never consulted the filename (audit CRITICAL, ImportCoordinator:228).
/// These are the founder's REAL recording filename shapes, enumerated from the production store.
@Suite("filenameMeta on real recording filenames")
struct FilenameMetaDateTests {

    private func meta(_ name: String) -> (title: String?, date: String?) {
        IngestEngine.filenameMeta(URL(fileURLWithPath: "/tmp/\(name)"))
    }

    @Test("Meet recording export: 'Title - YYYY-MM-DD HH-MM TZ - Recording-…'")
    func testMeetRecordingShape() {
        let m = meta("morning sync - 2026-06-30 09-29 PDT - Recording-1TtWzleA2WC9xxxx.mp4")
        #expect(m.date == "2026-06-30")
        #expect(m.title == "morning sync")
    }

    @Test("Quick-sync shape with person names and EDT timezone")
    func testQuickSyncShape() {
        let m = meta("Riley - Alex Quick Sync - 2026-06-25 17-15 EDT - Recording-abc.mp4")
        #expect(m.date == "2026-06-25")
    }

    @Test("Meet-code shape: 'xxx-yyyy-zzz (YYYY-MM-DD HH-MM GMT-7)-driveid'")
    func testMeetCodeShape() {
        let m = meta("fsq-iqhe-kam (2026-06-24 10-09 GMT-7)-1ETbeb8fqoFgrMUpxvmJWa.mp4")
        #expect(m.date == "2026-06-24")
    }

    @Test("Gemini notes docx shape (underscore dates)")
    func testGeminiNotesShape() {
        let m = meta("morning sync - 2026_06_29 09_29 PDT - Notes by Gemini (1).docx")
        #expect(m.date == "2026-06-29")
        #expect(m.title == "morning sync")
    }

    @Test("no date in filename → nil (caller falls back to file creation date, then today)")
    func testNoDate() {
        let m = meta("random voice memo.mp4")
        #expect(m.date == nil)
    }

    @Test("bogus month/day values are not accepted as dates")
    func testBogusDateRejected() {
        // A Drive ID with digit runs must not parse as a date.
        let m = meta("clip 9999_99_99 test.mp4")
        #expect(m.date == nil)
    }
}
