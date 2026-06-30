import SwiftUI

/// Renders an Ask-AI answer with real block markdown (headings, bullets, bold) and accent-colored
/// `[S#]` citation chips. Each `[S#]` is a TAP TARGET: clicking it opens the cited call at that exact
/// moment (founder ask 2026-06-30) — routed via a `callbrain://cite/S#` link to `onTapCite`.
struct MarkdownAnswerView: View {
    let text: String
    var citations: [Cite] = []
    var onTapCite: ((Cite) -> Void)? = nil
    @State private var sourcesExpanded = false

    struct WebSource: Identifiable, Equatable { let id: Int; let label: String; let url: URL }

    var body: some View {
        // Normalize a citation that the model wrote as a link (`[S1](url)` → `[S1]`) so it's styled as a
        // call citation, not mistaken for a web source (SME H4); then collapse web URLs.
        let content = Self.webContent(Self.stripCitationLinks(text))
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(Self.blocks(content.text).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
            if !content.sources.isEmpty { webSourcesFooter(content.sources) }
        }
        .tint(Theme.accent)   // citation + source links render in-brand, not system blue
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "callbrain", url.host == "cite" else { return .systemAction }  // web links → browser
            if let c = citations.first(where: { $0.tag == url.lastPathComponent }) { onTapCite?(c) }
            return .handled
        })
    }

    /// Collapsed list of the web sources cited in this answer (founder ask 2026-06-30) — so the prose shows
    /// clean clickable source names instead of dozens of raw URLs, with the full links one tap away.
    private func webSourcesFooter(_ sources: [WebSource]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Button { withAnimation(.snappy) { sourcesExpanded.toggle() } } label: {
                HStack(spacing: 5) {
                    Image(systemName: sourcesExpanded ? "chevron.down" : "chevron.right").font(.caption2)
                    Image(systemName: "globe").font(.caption2)
                    Text("Web sources · \(sources.count)").font(.caption)
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            if sourcesExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(sources) { src in
                        Link(destination: src.url) {
                            HStack(spacing: 6) {
                                Text("\(src.id).").font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                                Text(src.label).font(.caption).foregroundStyle(Theme.accent).lineLimit(1)
                                Image(systemName: "arrow.up.right.square").font(.caption2).foregroundStyle(.tertiary)
                                Spacer(minLength: 0)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.leading, 6).padding(.top, 1)
            }
        }
        .padding(.top, 5)
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

    /// `[S1](https://…)` → `[S1]`: a model occasionally formats a citation as a link, which the Markdown
    /// parser would render as bare `S1` (brackets eaten) and `webContent` would miscount as a web source.
    static func stripCitationLinks(_ s: String) -> String {
        // URL pattern allows one level of balanced parens (e.g. …/Foo_(bar)) so the link isn't truncated.
        guard let re = try? NSRegularExpression(pattern: #"\[(S\d+)\]\(https?://(?:[^\s()]|\([^\s()]*\))+\)"#) else { return s }
        let ns = s as NSString
        return re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: ns.length), withTemplate: "[$1]")
    }

    /// Rewrite the answer so the prose carries clean clickable source NAMES instead of long raw URLs, and
    /// collect every web link into a numbered, deduped list for the "Web sources" dropdown. A Markdown link
    /// `[label](url)` is kept (renders as just `label`); a bare `https://…` URL becomes `[host](url)`.
    static func webContent(_ s: String) -> (text: String, sources: [WebSource]) {
        // Bare-URL branch (group 2) allows ')' inside the URL; `trimURL` then strips trailing sentence
        // punctuation + any unbalanced closing paren back into the prose (SME M5 — Wikipedia-style URLs).
        // Markdown-link URL (group 1) allows one level of balanced parens so Wikipedia-style links aren't
        // truncated at the first ')'; bare URL (group 2) is cleaned by trimURL (SME).
        let pattern = #"\[[^\]]+\]\((https?://(?:[^\s()]|\([^\s()]*\))+)\)|(https?://[^\s\]]+)"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return (s, []) }
        let ns = s as NSString
        var out = ""; var cursor = 0
        var ordered: [String] = []; var seen = Set<String>()
        func note(_ u: String) { if seen.insert(u).inserted { ordered.append(u) } }
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            if m.range.location > cursor {
                out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            }
            if m.range(at: 1).location != NSNotFound {
                note(ns.substring(with: m.range(at: 1)))
                out += ns.substring(with: m.range)                 // keep the markdown link (clean label)
            } else if m.range(at: 2).location != NSNotFound {
                let raw = ns.substring(with: m.range(at: 2))
                let u = trimURL(raw)
                note(u)
                let host = URL(string: u)?.host?.replacingOccurrences(of: "www.", with: "") ?? "link"
                out += "[\(host)](\(u))"                            // bare URL → short domain link
                out += String(raw.dropFirst(u.count))              // trailing ")." etc. stays as prose
            }
            cursor = m.range.location + m.range.length
        }
        if cursor < ns.length { out += ns.substring(from: cursor) }
        let sources = ordered.enumerated().compactMap { (i, u) -> WebSource? in
            guard let url = URL(string: u) else { return nil }
            let label = url.host?.replacingOccurrences(of: "www.", with: "") ?? u
            return WebSource(id: i + 1, label: label, url: url)
        }
        return (out, sources)
    }

    /// Strip trailing sentence punctuation and any *unbalanced* closing paren from a captured bare URL, so
    /// a URL that legitimately contains balanced parens (…/Foo_(disambiguation)) is kept whole while a URL
    /// merely wrapped in prose parens "(see https://x.com/a)" doesn't swallow the closing ')'.
    static func trimURL(_ u: String) -> String {
        var s = Substring(u)
        while let last = s.last {
            if ".,;:!?\"'".contains(last) { s = s.dropLast(); continue }
            if last == ")" {
                let opens = s.filter { $0 == "(" }.count, closes = s.filter { $0 == ")" }.count
                if closes > opens { s = s.dropLast(); continue }
            }
            break
        }
        return String(s)
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

    /// Inline rendering: parse the WHOLE line's **bold**/*italic* markdown FIRST (so a bold span that
    /// contains a `[S#]` stays bold), then style each `[S#]` run in the accent color and turn it into a
    /// `callbrain://cite/S#` link (tap → open that call) when a matching citation exists.
    private func inline(_ s: String) -> Text {
        var attr = Self.md(s)
        guard let re = try? NSRegularExpression(pattern: #"\[S\d+\]"#) else { return Text(attr) }
        let ns = s as NSString
        let tags = Set(re.matches(in: s, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) })
        for tag in tags {
            let inner = String(tag.dropFirst().dropLast())           // "S8"
            let link = citations.contains(where: { $0.tag == inner }) ? URL(string: "callbrain://cite/\(inner)") : nil
            var start = attr.startIndex
            while start < attr.endIndex, let r = attr[start...].range(of: tag) {
                attr[r].foregroundColor = Theme.accent
                if let link { attr[r].link = link }
                start = r.upperBound
            }
        }
        return Text(attr)
    }

    static func md(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}
