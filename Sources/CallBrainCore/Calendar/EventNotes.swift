import Foundation

/// Calendar v3 — cleans provider event notes for display. Google Calendar descriptions are
/// HTML fragments, often with an auto-appended conference-info block fenced by
/// "-::~:~:: … ::~:~::-" divider lines; humans wrote none of that.
public enum EventNotes {

    /// nil when nothing human-readable remains — the panel hides the section entirely.
    public static func clean(_ raw: String?) -> String? {
        guard var s = raw, !s.isEmpty else { return nil }

        // 1. Google's conference-info boilerplate: drop everything from the first divider
        //    line to the last (a divider line's non-space characters are only -, :, ~).
        let lines = s.components(separatedBy: .newlines)
        let dividerIdxs = lines.indices.filter { isDivider(lines[$0]) }
        if let first = dividerIdxs.first, let last = dividerIdxs.last, first < last {
            s = (lines[..<first] + lines[(last + 1)...]).joined(separator: "\n")
        }

        // 2. HTML → text: line-break-ish tags become newlines, all other tags vanish.
        s = s.replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"</p>|</div>|</li>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)

        // 3. Common entities (full HTML decoding needs AppKit — these cover calendar reality).
        for (entity, char) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
                               ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " ")] {
            s = s.replacingOccurrences(of: entity, with: char)
        }

        // 4. Collapse blank-line runs, trim.
        s = s.replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    private static func isDivider(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.count >= 8 else { return false }
        return t.allSatisfy { "-:~".contains($0) }
    }
}
