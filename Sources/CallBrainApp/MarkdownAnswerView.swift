import SwiftUI
import MarkdownUI

/// Renders an Ask-AI answer with REAL markdown (perfection Task 4.1 — MarkdownUI: tables, fenced
/// code, nested lists, task-list checkboxes; the bespoke parser rendered `###` SMALLER than body,
/// audit CONFIRMED) plus quiet `[S#]` citations. Each is a TAP TARGET: `[S1]` is pre-linkified to a
/// `callbrain://cite/S1` link whose DISPLAY is a superscript footnote marker (¹) — the URL keeps the tag.
struct MarkdownAnswerView: View {
    let text: String
    var citations: [Cite] = []
    var onTapCite: ((Cite) -> Void)? = nil
    @State private var sourcesExpanded = false

    struct WebSource: Identifiable, Equatable { let id: Int; let label: String; let url: URL }
    // Cache the PARSED MarkdownContent (not just the string): `Markdown(String)` re-parses markdown→AST
    // on every body eval, so scrolling a long chat re-parses every visible answer → choppy/bogs-down
    // (founder). `Markdown(MarkdownContent)` takes pre-parsed content, so the parse happens once per answer.
    private struct RenderedContent { let content: MarkdownContent; let sources: [WebSource] }
    private static let renderCache = MarkdownRenderCache()

    var body: some View {
        // Normalize a citation that the model wrote as a link (`[S1](url)` → `[S1]`) so it's styled as a
        // call citation, not mistaken for a web source (SME H4); then collapse web URLs; then linkify chips.
        let known = Set(citations.map(\.tag))
        let content = Self.renderCache.render(text: text, known: known)
        VStack(alignment: .leading, spacing: 7) {
            Markdown(content.content)
                .markdownTheme(Self.answerTheme)
                .textSelection(.disabled)   // NEVER re-enable: .textSelection on this composite
                                            // caused the 2026-07-01 SelectionOverlay freeze
            if !content.sources.isEmpty { webSourcesFooter(content.sources) }
        }
        .tint(Theme.accent)   // citation + source links render in-brand, not system blue
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "callbrain", url.host == "cite" else { return .systemAction }  // web links → browser
            if let c = citations.first(where: { $0.tag == url.lastPathComponent }) { onTapCite?(c) }
            return .handled
        })
    }

    @MainActor private final class MarkdownRenderCache {
        private let lock = NSLock()
        private var order: [String] = []
        private var values: [String: RenderedContent] = [:]
        private let cap = 128

        func render(text: String, known: Set<String>) -> RenderedContent {
            let key = text + "\u{1f}" + known.sorted().joined(separator: ",")
            lock.lock()
            if let cached = values[key] {
                lock.unlock()
                return cached
            }
            lock.unlock()

            let web = MarkdownAnswerView.webContent(MarkdownAnswerView.stripCitationLinks(text))
            let linkified = MarkdownAnswerView.linkifyCitations(web.text, known: known)
            let rendered = RenderedContent(content: MarkdownContent(linkified), sources: web.sources)

            lock.lock()
            if values[key] == nil {
                values[key] = rendered
                order.append(key)
                while order.count > cap {
                    let removed = order.removeFirst()
                    values.removeValue(forKey: removed)
                }
            }
            let cached = values[key] ?? rendered
            lock.unlock()
            return cached
        }
    }

    /// `[S1]` → `[``S1``](callbrain://cite/S1)` for KNOWN citations — a code-span inside a link,
    /// which the theme renders as a small tinted capsule (the chip). Unknown tags stay plain text.
    /// Skips fenced code blocks AND inline code spans (phase-4 gate MED: rewriting inside code
    /// corrupts the rendering and chips non-citations).
    static func linkifyCitations(_ s: String, known: Set<String>) -> String {
        // Fenced segments (odd indices after splitting on ```) pass through untouched.
        let fenceParts = s.components(separatedBy: "```")
        return fenceParts.enumerated().map { i, part in
            guard i % 2 == 0 else { return part }        // inside a fence
            // Within prose, also skip inline `code` spans (odd indices after splitting on `).
            let codeParts = part.components(separatedBy: "`")
            return codeParts.enumerated().map { j, seg in
                j % 2 == 0 ? linkifyRun(seg, known: known) : seg
            }.joined(separator: "`")
        }.joined(separator: "```")
    }

    /// "S18" → "¹⁸": a quiet superscript footnote marker (replaces the old filled 10pt capsule) so
    /// citations stop speckling the prose. The `callbrain://cite/<tag>` URL keeps the REAL tag for taps.
    private static let superscriptDigits: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴",
        "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹"]
    static func superscriptTag(_ tag: String) -> String {
        String(tag.dropFirst().compactMap { superscriptDigits[$0] })
    }

    private static func linkifyRun(_ s: String, known: Set<String>) -> String {
        guard let re = try? NSRegularExpression(pattern: #"\[(S\d+)\]"#) else { return s }
        let ns = s as NSString
        var out = ""; var cursor = 0; var lastWasChip = false
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            if m.range.location > cursor {
                out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
                lastWasChip = false
            } else if lastWasChip {
                out += "\u{2009}"   // adjacent citations ("[S9][S10]") → a thin space so chips don't merge into "S9S10"
            }
            let tag = ns.substring(with: m.range(at: 1))            // "S8"
            let disp = Self.superscriptTag(tag)
            let isChip = known.contains(tag) && !disp.isEmpty
            out += isChip ? "[\(disp)](callbrain://cite/\(tag))" : ns.substring(with: m.range)
            lastWasChip = isChip
            cursor = m.range.location + m.range.length
        }
        if cursor < ns.length { out += ns.substring(from: cursor) }
        return out
    }

    /// The answer type scale (Task 4.1): h1 > h2 > h3 > BODY — the old parser inverted this.
    /// Inline code doubles as the citation-chip capsule (small, tinted, rounded).
    static let answerTheme = MarkdownUI.Theme()
        .text { FontSize(13); ForegroundColor(Theme.textPrimary) }
        .paragraph { cfg in cfg.label.relativeLineSpacing(.em(0.26)).markdownMargin(top: 0, bottom: 10) }
        // Confident, on-system hierarchy — 20 / 16 / small-caps label / 13 body. The old near-flat
        // 18/16/14-GREY scale (h3 quieter than body) made structured answers read as one wall.
        .heading1 { cfg in cfg.label.markdownTextStyle { FontSize(20); FontWeight(.semibold); ForegroundColor(Theme.textPrimary) }
            .markdownMargin(top: 16, bottom: 6) }
        .heading2 { cfg in cfg.label.markdownTextStyle { FontSize(16); FontWeight(.semibold); ForegroundColor(Theme.textPrimary) }
            .markdownMargin(top: 15, bottom: 6) }
        .heading3 { cfg in cfg.label.markdownTextStyle { FontSize(12.5); FontWeight(.semibold); ForegroundColor(Theme.textSecondary); FontCapsVariant(.smallCaps) }
            .markdownMargin(top: 12, bottom: 4) }
        // Real inline code (citations are NO LONGER code-spans — see linkifyRun): a quiet mono token.
        .code { FontSize(12); FontFamilyVariant(.monospaced); ForegroundColor(Theme.textSecondary); BackgroundColor(Theme.surfaceSunken) }
        // Citations are superscript footnote markers (accent, no fill, no underline) — quiet references
        // that don't speckle the prose. Web links share the accent tint.
        .link { ForegroundColor(Theme.accent) }
        .listItem { cfg in cfg.label.markdownMargin(top: 4, bottom: 4) }
        .taskListMarker { cfg in
            Image(systemName: cfg.isCompleted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(cfg.isCompleted ? Theme.accent : Color.secondary)
                .imageScale(.small)
        }
        .blockquote { cfg in
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 2).fill(Theme.accent).frame(width: 3)
                cfg.label.markdownTextStyle { ForegroundColor(.secondary) }
            }
        }
        .table { cfg in cfg.label.markdownMargin(top: 6, bottom: 6) }
        .codeBlock { cfg in
            ScrollView(.horizontal, showsIndicators: false) {
                cfg.label
                    .markdownTextStyle { FontSize(11.5); FontFamilyVariant(.monospaced) }
                    .padding(10)
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.cardFill))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.hairline))
            .markdownMargin(top: 6, bottom: 8)
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
}
