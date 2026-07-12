import Testing
import Foundation
@testable import CallBrainCore

/// Calendar v3 — event-notes cleaning for the detail panel. Google Calendar descriptions
/// arrive as HTML fragments with an auto-appended "-::~:~:: … ::~:~::-" conference-info
/// boilerplate block; the panel must show human notes only.
@Suite("Event notes cleaning (v3)")
struct EventNotesTests {

    @Test("html tags strip; <br> and </p> become line breaks")
    func testHTML() {
        let got = EventNotes.clean("<p>Agenda:</p><p>1. Numbers<br>2. Hiring</p>")
        #expect(got == "Agenda:\n1. Numbers\n2. Hiring")
    }

    @Test("the Google Meet boilerplate block vanishes; real notes before it survive")
    func testGoogleBoilerplate() {
        let raw = """
        Prep doc attached.

        -::~:~::~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~::~:~::-
        Join with Google Meet: https://meet.google.com/gpm-ysrk-vcf
        Or dial: (GB) +44 20 3937 0940 PIN: 902627396#
        More phone numbers: https://tel.meet/gpm-ysrk-vcf?pin=902627396
        -::~:~::~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~::~:~::-
        """
        #expect(EventNotes.clean(raw) == "Prep doc attached.")
    }

    @Test("empty-after-cleaning returns nil (the panel hides the section)")
    func testEmpty() {
        #expect(EventNotes.clean("<p></p>") == nil)
        #expect(EventNotes.clean("   \n\n  ") == nil)
        #expect(EventNotes.clean(nil) == nil)
    }

    @Test("plain human notes pass through; entities decode")
    func testPlain() {
        #expect(EventNotes.clean("Bring the Q3 deck &amp; budget") == "Bring the Q3 deck & budget")
        #expect(EventNotes.clean("Notes about A &lt; B") == "Notes about A < B")
    }
}
