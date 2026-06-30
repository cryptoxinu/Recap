import SwiftUI

/// Renders an Ask-AI answer with real block markdown (headings, bullets, bold) and accent-colored
/// `[S#]` citation chips — so answers read like a polished product, not raw text.
struct MarkdownAnswerView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(Self.blocks(text).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
    }

    enum Block: Equatable {
        case heading(level: Int, String)
        case bullet(String)
        case paragraph(String)
        case rule
    }

    @ViewBuilder
    private func view(for block: Block) -> some View {
        switch block {
        case .heading(let level, let s):
            inline(s)
                .font(level <= 1 ? .title3.bold() : level == 2 ? .headline : .subheadline.bold())
                .padding(.top, 3)
        case .bullet(let s):
            HStack(alignment: .top, spacing: 8) {
                Text("•").foregroundStyle(Theme.accent).bold()
                inline(s).frame(maxWidth: .infinity, alignment: .leading)
            }
        case .paragraph(let s):
            inline(s).frame(maxWidth: .infinity, alignment: .leading)
        case .rule:
            Divider().padding(.vertical, 2)
        }
    }

    static func blocks(_ text: String) -> [Block] {
        var out: [Block] = []
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line == "---" || line == "***" { out.append(.rule) }
            else if line.hasPrefix("### ") { out.append(.heading(level: 3, String(line.dropFirst(4)))) }
            else if line.hasPrefix("## ") { out.append(.heading(level: 2, String(line.dropFirst(3)))) }
            else if line.hasPrefix("# ") { out.append(.heading(level: 1, String(line.dropFirst(2)))) }
            else if line.hasPrefix("- ") || line.hasPrefix("* ") { out.append(.bullet(String(line.dropFirst(2)))) }
            else if let m = line.range(of: #"^\d+\.\s"#, options: .regularExpression) {
                out.append(.bullet(String(line[m.upperBound...])))
            } else { out.append(.paragraph(line)) }
        }
        return out
    }

    /// Inline rendering: **bold**/*italic* via AttributedString markdown, plus accent `[S#]` chips,
    /// built as a single concatenated `Text`.
    private func inline(_ s: String) -> Text {
        guard let re = try? NSRegularExpression(pattern: #"\[S\d+\]"#) else { return Text(Self.md(s)) }
        let ns = s as NSString
        let matches = re.matches(in: s, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return Text(Self.md(s)) }

        var result = Text("")
        var cursor = 0
        for m in matches {
            if m.range.location > cursor {
                result = result + Text(Self.md(ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))))
            }
            result = result + Text(ns.substring(with: m.range)).foregroundColor(Theme.accent).bold()
            cursor = m.range.location + m.range.length
        }
        if cursor < ns.length {
            result = result + Text(Self.md(ns.substring(from: cursor)))
        }
        return result
    }

    static func md(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}
