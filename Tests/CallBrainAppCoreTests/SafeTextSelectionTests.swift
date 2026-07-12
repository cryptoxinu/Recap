import Foundation
import Testing
@testable import CallBrainAppCore

@Suite("Safe text selection")
struct SafeTextSelectionTests {
    @Test("clamps stale selections to the replacement text's UTF-16 length")
    func clampsStaleSelection() {
        let range = SafeTextSelection.clamped(NSRange(location: 8, length: 4), textUTF16Length: 3)
        #expect(range.location == 3)
        #expect(range.length == 0)
    }

    @Test("preserves valid in-bounds selections")
    func preservesValidSelection() {
        let range = SafeTextSelection.clamped(NSRange(location: 2, length: 3), textUTF16Length: 8)
        #expect(range.location == 2)
        #expect(range.length == 3)
    }

    @Test("NSNotFound location collapses to a caret at the end of the replacement")
    func notFoundLocationGoesToEnd() {
        let range = SafeTextSelection.clamped(NSRange(location: NSNotFound, length: 0), textUTF16Length: 5)
        #expect(range.location == 5)
        #expect(range.length == 0)
    }

    @Test("an empty replacement clamps any selection to the start")
    func emptyReplacementClampsToStart() {
        let range = SafeTextSelection.clamped(NSRange(location: 4, length: 2), textUTF16Length: 0)
        #expect(range.location == 0)
        #expect(range.length == 0)
    }

    @Test("a caret exactly at the end is valid; a length past the end is trimmed")
    func caretAtEndAndOverlongLength() {
        let caret = SafeTextSelection.clamped(NSRange(location: 5, length: 0), textUTF16Length: 5)
        #expect(caret.location == 5 && caret.length == 0)
        let overlong = SafeTextSelection.clamped(NSRange(location: 3, length: 99), textUTF16Length: 5)
        #expect(overlong.location == 3 && overlong.length == 2)
    }
}

