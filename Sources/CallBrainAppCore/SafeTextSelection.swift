import Foundation

public enum SafeTextSelection {
    /// Clamp an AppKit text selection to a replacement string's UTF-16 length. `NSTextView` selection
    /// APIs use `NSRange`, so UTF-16 length is the correct bound for Swift `String` replacements.
    public static func clamped(_ range: NSRange, textUTF16Length: Int) -> NSRange {
        let upperBound = max(0, textUTF16Length)
        let rawLocation = range.location == NSNotFound ? upperBound : range.location
        let location = min(max(0, rawLocation), upperBound)
        let length = min(max(0, range.length), max(0, upperBound - location))
        return NSRange(location: location, length: length)
    }
}

