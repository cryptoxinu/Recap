import SwiftUI
import CallBrainCore

struct MeetingDetailView: View {
    @Environment(AppEnvironment.self) private var env
    let meetingID: String
    /// A cited chunk to scroll to + flash. Dynamic: when the parent (the workspace) changes it on a
    /// citation tap, the transcript scrolls to the matching turn (timestamp-linked navigation).
    var highlightChunkID: String? = nil

    @State private var meeting: Store.MeetingRow?
    @State private var groups: [TurnGroup] = []
    @State private var noteLines: [String] = []      // populated for Gemini-notes meetings
    @State private var people: [Entity] = []         // native-NER people mentioned
    @State private var highlightGroupID: Int?

    // Find-in-transcript
    @State private var findActive = false
    @State private var findText = ""
    @State private var matchIndex = 0

    private var isNotes: Bool { meeting?.source == "gmeet_gemini" }

    struct TurnGroup: Identifiable {
        let id: Int
        let speaker: String
        let tStart: Double?
        let isInferred: Bool
        var lines: [String]
        var joined: String { lines.joined(separator: " ") }
    }

    /// Group ids matching the find query (transcript), in order.
    private var matches: [Int] {
        let q = findText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        return groups.filter { $0.joined.lowercased().contains(q) || $0.speaker.lowercased().contains(q) }.map(\.id)
    }
    /// Note lines matching the find query (Gemini notes render as one collapsed group, so the transcript
    /// `matches` count would always be 1 — count actual lines instead; gate LOW).
    private var noteMatchCount: Int {
        let q = findText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return 0 }
        return noteLines.filter { $0.lowercased().contains(q) }.count
    }
    /// The cited note snippet to accent-tint (Gemini notes have no scroll anchors; gate MED).
    private var citedNoteSnippet: String {
        guard isNotes, let cid = highlightChunkID, let hit = (try? env.store.chunks(ids: [cid]))?.first
        else { return "" }
        return String(hit.text.prefix(60))
    }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                if findActive { findBar(proxy) }
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header
                        Divider()
                        if isNotes {
                            GeminiNotesView(lines: noteLines, title: meeting?.title,
                                            highlight: findText, citedSnippet: citedNoteSnippet)
                        } else {
                            LazyVStack(alignment: .leading, spacing: 16) {
                                ForEach(groups) { turn($0).id($0.id) }
                            }
                        }
                    }
                    .padding(28)
                    .frame(maxWidth: 860, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .task {
                await load()
                // Screenshot QA: CALLBRAIN_FIND=<query> opens the Find bar pre-filled.
                if let f = ProcessInfo.processInfo.environment["CALLBRAIN_FIND"], !f.isEmpty {
                    findActive = true; findText = f
                    if let first = matches.first { scrollTo(first, proxy) }
                }
                await scrollToHighlight(proxy)
            }
            .onChange(of: highlightChunkID) { _, _ in
                Task { recomputeHighlight(); await scrollToHighlight(proxy) }
            }
        }
        .navigationTitle(meeting?.title ?? "Meeting")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button { withAnimation(.snappy) { findActive.toggle() } } label: {
                    Image(systemName: "magnifyingglass")
                }
                .help("Find in transcript")
            }
        }
    }

    private func findBar(_ proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(isNotes ? "Find in notes…" : "Find in transcript…", text: $findText)
                .textFieldStyle(.plain)
                .onSubmit { jump(+1, proxy) }
                .onChange(of: findText) { _, _ in matchIndex = 0; if !isNotes, let f = matches.first { scrollTo(f, proxy) } }
            if isNotes {
                // Notes have no scroll anchors → highlight-only, but report the real matching-line count.
                if noteMatchCount > 0 {
                    Text("\(noteMatchCount) match\(noteMatchCount == 1 ? "" : "es")")
                        .font(.caption).foregroundStyle(.secondary)
                } else if !findText.isEmpty {
                    Text("No matches").font(.caption).foregroundStyle(.secondary)
                }
            } else if !matches.isEmpty {
                Text("\(min(matchIndex + 1, matches.count)) / \(matches.count)")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Button { jump(-1, proxy) } label: { Image(systemName: "chevron.up") }.buttonStyle(.plain)
                Button { jump(+1, proxy) } label: { Image(systemName: "chevron.down") }.buttonStyle(.plain)
            } else if !findText.isEmpty {
                Text("No matches").font(.caption).foregroundStyle(.secondary)
            }
            Button { withAnimation(.snappy) { findActive = false; findText = "" } } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(Theme.cardFill)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func jump(_ dir: Int, _ proxy: ScrollViewProxy) {
        guard !matches.isEmpty else { return }
        matchIndex = ((matchIndex + dir) % matches.count + matches.count) % matches.count
        scrollTo(matches[matchIndex], proxy)
    }

    private func scrollTo(_ id: Int, _ proxy: ScrollViewProxy) {
        withAnimation(.easeInOut) { proxy.scrollTo(id, anchor: .center) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(meeting?.title ?? "Meeting").font(.largeTitle).bold()
            if let m = meeting {
                HStack(spacing: 14) {
                    Label(m.date, systemImage: "calendar")
                    Label(sourceLabel(m.source), systemImage: "doc.text")
                    if isNotes {
                        Label("AI meeting notes", systemImage: "sparkles")
                    } else {
                        Label("\(groups.count) turns", systemImage: "bubble.left.and.bubble.right")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            if !people.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(people) { Chip(text: $0.name, icon: "person.fill") }
                }
                .padding(.top, 2)
            }
        }
    }

    private func turn(_ g: TurnGroup) -> some View {
        let isMatch = !findText.isEmpty && matches.contains(g.id)
        let isCurrentMatch = isMatch && matches.indices.contains(matchIndex) && matches[matchIndex] == g.id
        return HStack(alignment: .top, spacing: 12) {
            avatar(g.speaker)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(g.speaker).font(.subheadline).bold().foregroundStyle(color(for: g.speaker))
                    if let t = g.tStart, t > 0 {
                        Text(timestamp(t)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    if g.isInferred {
                        Text("inferred").font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(.secondary.opacity(0.15), in: Capsule()).foregroundStyle(.secondary)
                    }
                }
                ForEach(Array(g.lines.enumerated()), id: \.offset) { _, line in
                    Text(line).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        .lineSpacing(2).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(turnFill(g.id, isMatch: isMatch, isCurrent: isCurrentMatch)))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(isCurrentMatch ? Color.yellow.opacity(0.7) : .clear, lineWidth: 1.5))
    }

    private func turnFill(_ id: Int, isMatch: Bool, isCurrent: Bool) -> Color {
        if id == highlightGroupID { return Theme.accent.opacity(0.14) }
        if isCurrent { return Color.yellow.opacity(0.18) }
        if isMatch { return Color.yellow.opacity(0.08) }
        return .clear
    }

    private func avatar(_ name: String) -> some View {
        let initials = name.split(separator: " ").prefix(2).compactMap { $0.first.map(String.init) }.joined()
        return Text(initials.isEmpty ? "•" : initials.uppercased())
            .font(.caption.bold()).foregroundStyle(.white)
            .frame(width: 30, height: 30).background(color(for: name), in: Circle())
    }

    private func color(for name: String) -> Color {
        let palette: [Color] = [Theme.accent, .blue, .teal, .green, .orange, .pink, .indigo, .red, .mint]
        var h = 5381
        for b in name.utf8 { h = (h &* 33) &+ Int(b) }
        return palette[(h & 0x7fffffff) % palette.count]
    }

    private func sourceLabel(_ s: String) -> String {
        switch s {
        case "gmeet_gemini": "Google Meet (Gemini notes)"
        case "gmeet_local", "gmeet_cloud": "Google Meet"
        case "fireflies": "Fireflies"
        case "fathom": "Fathom"
        case "cluely": "Cluely"
        case "paste": "Pasted / AI-resolved"
        default: s
        }
    }

    private func timestamp(_ s: Double) -> String {
        let total = Int(s)
        let h = total / 3600, m = (total % 3600) / 60, sec = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    private func scrollToHighlight(_ proxy: ScrollViewProxy) async {
        guard let h = highlightGroupID else { return }
        try? await Task.sleep(for: .milliseconds(120))
        withAnimation(.easeInOut) { proxy.scrollTo(h, anchor: .center) }
    }

    /// Map the cited chunk to a transcript group (best-effort text match).
    private func recomputeHighlight() {
        guard let cid = highlightChunkID, let hit = (try? env.store.chunks(ids: [cid]))?.first else {
            highlightGroupID = nil; return
        }
        let needle = String(hit.text.prefix(40)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { highlightGroupID = nil; return }
        highlightGroupID = groups.first(where: { g in
            g.lines.contains(where: { $0.contains(needle) || needle.contains($0.prefix(30)) })
        })?.id
    }

    private func load() async {
        if let m = try? env.store.meeting(id: meetingID) { meeting = m }
        let utts = (try? env.store.utterances(meetingID: meetingID)) ?? []
        if meeting?.source == "gmeet_gemini" {
            noteLines = utts.map(\.text)
        } else {
            people = ((try? env.store.entities(meetingID: meetingID)) ?? [])
                .filter { $0.kind == .person && $0.count >= 2 }.prefix(10).map { $0 }
        }
        let rows: [(speaker: String, t: Double?, inferred: Bool, text: String)]
        if utts.isEmpty {
            rows = ((try? env.store.transcript(meetingID: meetingID)) ?? [])
                .map { (speaker: $0.speaker ?? "—", t: $0.tStart, inferred: false, text: $0.text) }
        } else {
            rows = utts.map { (speaker: $0.speaker ?? "—", t: $0.tStart, inferred: $0.isInferred, text: $0.text) }
        }
        var result: [TurnGroup] = []
        for r in rows {
            if let last = result.last, last.speaker == r.speaker {
                result[result.count - 1].lines.append(r.text)
            } else {
                result.append(TurnGroup(id: result.count, speaker: r.speaker, tStart: r.t,
                                        isInferred: r.inferred, lines: [r.text]))
            }
        }
        groups = result
        recomputeHighlight()
    }
}
