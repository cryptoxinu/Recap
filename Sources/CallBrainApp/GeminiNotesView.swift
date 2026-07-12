import SwiftUI
import AppKit
import CallBrainCore

/// Renders a Google-Meet "Notes by Gemini" meeting as clean, Fireflies-style notes — an intro block
/// (lead summary + participant chips), then section headers with bulleted points — NOT a transcript
/// wall (founder requirement, docs/STATE.md §9). Input is the persisted note lines (one per utterance).
struct GeminiNotesView: View {
    @Environment(AppEnvironment.self) private var env
    let lines: [String]
    var title: String? = nil
    var highlight: String = ""           // Find-in-notes: yellow-tint matching points
    var citedSnippet: String = ""        // a tapped AskFred citation: accent-tint the cited note
    var meetingID: String? = nil         // enables "Explain This" routing to the docked AskFred

    private func matchesFind(_ s: String) -> Bool {
        let q = highlight.trimmingCharacters(in: .whitespaces).lowercased()
        return !q.isEmpty && s.lowercased().contains(q)
    }
    private func matchesCite(_ s: String) -> Bool {
        let q = citedSnippet.trimmingCharacters(in: .whitespaces).lowercased()
        guard q.count >= 6 else { return false }
        let l = s.lowercased()
        return l.contains(q) || q.contains(l.prefix(30))
    }

    private struct Section: Identifiable { let id: Int; let title: String?; var points: [String] }

    var body: some View {
        if sections.isEmpty {
            // Empty notes rendered as a blank pane (intro + sections both produced nothing) — show
            // an honest empty state instead (audit G3 MED).
            ContentUnavailableView("No notes for this call", systemImage: "doc.text",
                                   description: Text("This call has no Gemini notes to show."))
                .frame(maxWidth: .infinity, minHeight: 200)
        } else {
            notesBody
        }
    }

    private var notesBody: some View {
        VStack(alignment: .leading, spacing: 18) {
            intro
            ForEach(sections) { section in
                VStack(alignment: .leading, spacing: 9) {
                    if let t = section.title {
                        Text(t).font(.title3.bold())
                            .padding(.bottom, 1)
                            .overlay(alignment: .bottomLeading) {
                                Rectangle().fill(Theme.accent.opacity(0.5))
                                    .frame(width: 34, height: 2).offset(y: 4)
                            }
                    }
                    ForEach(Array(section.points.enumerated()), id: \.offset) { _, p in
                        point(p)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: intro (summary + participants), drawn from the lines before the first real section

    @ViewBuilder private var intro: some View {
        let info = introInfo
        if info.summary != nil || !info.participants.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                if let s = info.summary {
                    Text(s).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !info.participants.isEmpty {
                    FlowChips(items: info.participants)
                }
            }
            .padding(.bottom, 2)
        }
    }

    private struct IntroInfo { var summary: String?; var participants: [String]; var consumed: Set<String> }

    /// Classify the pre-section lines: a date (drop — it's in the header meta), the participant roster
    /// (≥3 capitalized name-pairs, no sentence period), and the summary (a sentence ending in '.'). Every
    /// line the intro actually CONSUMES is recorded so `sections` can drop exactly those (and only those) —
    /// any pre-section line that matches none of the three buckets stays a normal point instead of vanishing.
    private var introInfo: IntroInfo {
        var info = IntroInfo(summary: nil, participants: [], consumed: [])
        for line in introLines {
            if isDateLine(line) { info.consumed.insert(line); continue }
            if line.hasSuffix(".") && line.contains(" ") && line.count > 40 {
                // Keep ONLY the first summary sentence; a second long sentence must stay a normal section
                // point rather than being consumed-but-not-rendered (audit LOW: silent content loss).
                if info.summary == nil { info.summary = line; info.consumed.insert(line) }
            } else if let names = rosterNames(line) {
                info.participants = names
                info.consumed.insert(line)
            }
        }
        return info
    }

    /// Non-heading lines before the first *real* section, skipping a leading heading that merely
    /// repeats the meeting title (Gemini emits `## <title>` then date/roster/summary, then sections).
    private var introLines: [String] {
        var result: [String] = []
        for line in lines where !line.isEmpty {
            if line.hasPrefix("## ") {
                if String(line.dropFirst(3)).caseInsensitiveCompare(title ?? "") == .orderedSame { continue }
                break
            }
            result.append(line)
        }
        return result
    }

    private func isDateLine(_ s: String) -> Bool {
        s.range(of: #"^[A-Z][a-z]{2,8}\s+\d{1,2},\s+\d{4}$"#, options: .regularExpression) != nil
    }

    /// A roster line is several capitalized words (first/last name pairs) with no sentence punctuation.
    private func rosterNames(_ s: String) -> [String]? {
        guard !s.contains("."), !s.contains(":"), !s.hasPrefix("[") else { return nil }
        let words = s.split(separator: " ").map(String.init)
        guard words.count >= 4, words.allSatisfy({ $0.first?.isUppercase == true }) else { return nil }
        // Pair consecutive words into "First Last" names.
        var names: [String] = []
        var i = 0
        while i < words.count {
            if i + 1 < words.count { names.append("\(words[i]) \(words[i + 1])"); i += 2 }
            else { names.append(words[i]); i += 1 }
        }
        return names.count >= 2 ? names : nil
    }

    // MARK: points

    private func point(_ s: String) -> some View {
        let clean = s.hasPrefix("•") ? String(s.dropFirst()).trimmingCharacters(in: .whitespaces) : s
        return HStack(alignment: .top, spacing: 10) {
            Circle().fill(Theme.accent.opacity(0.7)).frame(width: 5, height: 5).padding(.top, 7)
            actionItem(clean)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 1).padding(.horizontal, Space.xs)
        .background(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).fill(
            matchesCite(clean) ? Theme.accentSoft : (matchesFind(clean) ? Theme.warningSoft : .clear)))
        .contextMenu {   // right-click → copy this note line (plus drag-select)
            if let meetingID {
                Button {
                    env.explainRequest = .init(text: clean, meetingID: meetingID)   // Task 4.5
                } label: { Label("Explain This", systemImage: "questionmark.bubble") }
                Divider()
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(clean, forType: .string)
            } label: { Label("Copy line", systemImage: "doc.on.doc") }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
            } label: { Label("Copy all notes", systemImage: "doc.on.doc.fill") }
        }
    }

    /// `[Owner] rest` → an accent owner chip + the text; otherwise plain.
    private func actionItem(_ s: String) -> Text {
        if s.hasPrefix("["), let close = s.firstIndex(of: "]") {
            let owner = String(s[s.index(after: s.startIndex)..<close])
            let rest = String(s[s.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            return Text(owner).bold().foregroundColor(Theme.accent) + Text("  " + rest)
        }
        return Text(s)
    }

    // MARK: sections

    private var sections: [Section] {
        var out: [Section] = []
        var current = Section(id: 0, title: nil, points: [])
        var sawHeading = false
        // Drop ONLY the pre-section lines the intro block actually rendered (date/summary/roster) — a
        // pre-section line that matched none of those buckets is NOT swallowed; it falls through as a point.
        let consumed = introInfo.consumed
        for line in lines where !line.isEmpty {
            if line.hasPrefix("## ") {
                let t = String(line.dropFirst(3))
                if t.caseInsensitiveCompare(title ?? "") == .orderedSame { continue }  // dup of header title
                if sawHeading || !current.points.isEmpty { out.append(current) }
                current = Section(id: out.count + 1, title: t, points: [])
                sawHeading = true
            } else if line.hasPrefix("### ") {
                current.points.append(String(line.dropFirst(4)))
            } else if !sawHeading && consumed.contains(line) {
                continue                                          // rendered by the intro block
            } else {
                current.points.append(line)
            }
        }
        if !current.points.isEmpty || current.title != nil { out.append(current) }
        return out
    }
}

/// Simple wrapping chip row for participant names.
private struct FlowChips: View {
    let items: [String]
    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(items, id: \.self) { Chip(text: $0) }
        }
    }
}
