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
    @State private var tasks: [ActionItem] = []      // action items for this call (Summary tab)
    @State private var tab: Tab = .summary
    @State private var didAutoSummarize = false

    // Find-in-transcript
    @State private var findActive = false
    @State private var findText = ""
    @State private var matchIndex = 0

    enum Tab: String, CaseIterable { case summary = "Summary", transcript = "Transcript" }

    private var isNotes: Bool { meeting?.source == "gmeet_gemini" }
    /// Every call shows Summary | Transcript tabs (founder ask). For a Gemini call the Transcript tab holds
    /// Google's full notes (there's no word-for-word transcript), and the Summary tab a concise digest.
    private var showsTabs: Bool { true }
    private var hasSummary: Bool { !(meeting?.callSummary?.isEmpty ?? true) }

    struct TurnGroup: Identifiable, Sendable {
        let id: Int
        let speaker: String
        let tStart: Double?
        let isInferred: Bool
        var lines: [String]
        var joined: String { lines.joined(separator: " ") }
    }

    /// Everything the detail view loads for a call — built OFF the main thread so opening a large call
    /// never freezes navigation.
    struct LoadSnapshot: Sendable {
        var meeting: Store.MeetingRow?
        var tasks: [ActionItem] = []
        var people: [Entity] = []
        var noteLines: [String] = []
        var groups: [TurnGroup] = []
    }

    /// Group ids matching the find query (transcript), in order — CACHED so it's computed once per query
    /// change, not re-filtered for every row (that was O(n²) on long transcripts).
    @State private var matchIDs: [Int] = []
    @State private var matchSet: Set<Int> = []
    private var matches: [Int] { matchIDs }
    private func recomputeMatches() {
        let q = findText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { matchIDs = []; matchSet = []; return }
        matchIDs = groups.filter { $0.joined.lowercased().contains(q) || $0.speaker.lowercased().contains(q) }.map(\.id)
        matchSet = Set(matchIDs)
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
                if findActive { findBar(proxy).transition(.move(edge: .top).combined(with: .opacity)) }
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header
                        tabPicker
                        Divider()
                        tabContent.animation(Theme.springy, value: tab)
                    }
                    .padding(28)
                    .frame(maxWidth: 860, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .task {
                await load()
                await autoSummarizeIfNeeded()
                // Screenshot QA: CALLBRAIN_FIND=<query> opens the Find bar pre-filled.
                if let f = ProcessInfo.processInfo.environment["CALLBRAIN_FIND"], !f.isEmpty {
                    findActive = true; findText = f
                    if showsTabs { tab = .transcript }           // mount the transcript so matches scroll
                    recomputeMatches()
                    if let first = matchIDs.first { scrollTo(first, proxy) }
                }
                await scrollToHighlight(proxy)
            }
            .onChange(of: highlightChunkID) { _, _ in
                Task { recomputeHighlight(); await scrollToHighlight(proxy) }
            }
            .onChange(of: env.titlesRevision) { _, _ in Task { await reloadMeta() } }
        }
        .navigationTitle(meeting?.displayTitle ?? "Meeting")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    withAnimation(.snappy) { findActive.toggle(); if findActive, showsTabs { tab = .transcript } }
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .help(isNotes ? "Find in notes" : "Find in transcript")
            }
        }
    }

    private func findBar(_ proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(isNotes ? "Find in notes…" : "Find in transcript…", text: $findText)
                .textFieldStyle(.plain)
                .onSubmit { jump(+1, proxy) }
                .onChange(of: findText) { _, _ in
                    matchIndex = 0; recomputeMatches()
                    if !isNotes, let f = matchIDs.first { scrollTo(f, proxy) }
                }
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

    /// True when the AI gave the call a meaningful name that differs from its raw (often date-stamp) title.
    private var renamed: Bool {
        guard let m = meeting else { return false }
        return (m.aiTitle?.isEmpty == false) && m.aiTitle != m.title
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(meeting?.displayTitle ?? "Meeting").font(.largeTitle).bold()
            if let s = meeting?.aiSummary, !s.isEmpty {
                Text(s).font(.title3).foregroundStyle(.secondary)
            }
            if let m = meeting {
                HStack(spacing: 14) {
                    Label(m.date, systemImage: "calendar")
                    Label(sourceLabel(m.source), systemImage: "doc.text")
                    if renamed { Label(m.title, systemImage: "tag").lineLimit(1) }   // original title
                    if isNotes {
                        Label("AI meeting notes", systemImage: "sparkles")
                    } else {
                        Label("\(groups.count) turns", systemImage: "bubble.left.and.bubble.right")
                    }
                    if m.category != nil { CategoryTag(category: CallCategory(stored: m.category)) }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            if !people.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(people) { Chip(text: $0.name, icon: "person.fill") }
                }
                .padding(.top, 2)
                .animation(Theme.springy, value: people.map(\.name))
                .transition(.opacity)
            }
        }
    }

    private var tabPicker: some View {
        Picker("View", selection: $tab) {
            ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 280, alignment: .leading)
    }

    /// Summary | Transcript panes — each fades as the tab switches (no hard cut).
    @ViewBuilder private var tabContent: some View {
        switch tab {
        case .summary:
            summaryTab.transition(.opacity)
        case .transcript:
            if isNotes {
                // A Gemini call's "transcript" is Google's full notes (no verbatim transcript).
                GeminiNotesView(lines: noteLines, title: meeting?.title,
                                highlight: findText, citedSnippet: citedNoteSnippet)
                    .transition(.opacity)
            } else {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(groups) { turn($0).id($0.id) }
                }
                .animation(Theme.springy, value: groups.count)
                .transition(.opacity)
            }
        }
    }

    // MARK: - Summary tab

    private var isSummarizing: Bool { env.summaries.isWorking(on: meetingID) }
    private var isQueued: Bool { env.summaries.isQueued(meetingID) }
    private var autoPaused: Bool { env.summaries.autoPausedForPower }

    @ViewBuilder private var summaryTab: some View {
        VStack(alignment: .leading, spacing: 24) {
            actionItemsSection
            summaryBody
        }
    }

    @ViewBuilder private var actionItemsSection: some View {
        if !tasks.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Label("Action items", systemImage: "checklist").font(.headline)
                ForEach(tasks) { actionRow($0) }
            }
            .animation(Theme.springy, value: tasks)
        }
    }

    private func actionRow(_ item: ActionItem) -> some View {
        Button { toggleTask(item) } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: item.status == .done ? "checkmark.circle.fill" : "circle")
                    .contentTransition(.symbolEffect(.replace))
                    .foregroundStyle(item.status == .done ? Theme.accent : Color.secondary)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.text)
                        .strikethrough(item.status == .done)
                        .foregroundStyle(item.status == .done ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let o = item.owner, !o.isEmpty {
                        Text(o).font(.caption).foregroundStyle(Theme.accent)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var summaryBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Summary", systemImage: "doc.text").font(.headline)
                Spacer()
                summaryStatusLabel
            }
            Group {
                if let s = meeting?.callSummary, !s.isEmpty {
                    MarkdownAnswerView(text: s).transition(.opacity)
                } else if isSummarizing {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Summarizing locally…").foregroundStyle(.secondary)
                    }
                    .transition(.opacity)
                } else {
                    Text(autoPaused
                         ? "Summary paused to save battery — generate it now below."
                         : (isNotes ? "Summarizing Google's notes… (full notes are on the Transcript tab)"
                                    : "No summary yet — generate one below."))
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
            }
            .animation(Theme.smooth, value: meeting?.callSummary)
            .animation(Theme.smooth, value: isSummarizing)
            regenerateBar
        }
    }

    @ViewBuilder private var summaryStatusLabel: some View {
        if isNotes && !hasSummary {
            Label("Google's notes", systemImage: "sparkles").font(.caption).foregroundStyle(.secondary)
        } else if meeting?.summarySource == "cloud" {
            Label("AI · premium", systemImage: "sparkles").font(.caption).foregroundStyle(.secondary)
        } else if hasSummary {
            Label("On-device model", systemImage: "cpu").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var regenerateBar: some View {
        HStack(spacing: 12) {
            if isSummarizing || isQueued {
                ProgressView().controlSize(.small)
                Text(isSummarizing ? "Summarizing…" : "Queued…").font(.caption).foregroundStyle(.secondary)
            } else {
                Button { generate(cloud: false) } label: {
                    Label(hasSummary ? "Regenerate" : "Generate summary", systemImage: "arrow.clockwise")
                }
                Button { generate(cloud: true) } label: { Label("Regenerate with AI", systemImage: "sparkles") }
                    .help("Use your Claude / Codex subscription for a premium-quality pass")
            }
        }
        .font(.callout)
        .padding(.top, 2)
    }

    private func generate(cloud: Bool) { env.summaries.requestNow(meetingID, cloud: cloud) }

    private func toggleTask(_ item: ActionItem) {
        let next: ActionItem.Status = item.status == .done ? .open : .done
        // Only reflect the toggle in the UI if the row actually changed; otherwise reload so the checklist
        // never lies about a task that was deleted/reconciled away.
        if (try? env.store.setTaskStatus(id: item.id, next)) == true {
            withAnimation(Theme.springy) {
                if let i = tasks.firstIndex(where: { $0.id == item.id }) { tasks[i].status = next }
            }
            env.refreshReminders()
        } else {
            Task { await reloadMeta() }
        }
    }

    /// Auto-generate a local summary the first time a non-Gemini call is opened without one (the import
    /// pass usually beat us here; this covers calls imported before the feature). Battery-gated by the
    /// scheduler. Gemini calls reuse Google's notes — no generation.
    private func autoSummarizeIfNeeded() async {
        guard !didAutoSummarize, !hasSummary else { return }   // every call gets a digest, Gemini included
        didAutoSummarize = true
        env.summaries.enqueueAuto(meetingID)
    }

    /// Refresh just the meeting row + tasks (after a summary/regenerate lands) without rebuilding the
    /// transcript groups.
    private func reloadMeta() async {
        let m = try? env.store.meeting(id: meetingID)
        let t = (try? env.store.tasks(meetingID: meetingID)) ?? []
        withAnimation(Theme.springy) {   // title/category/summary settle in, not pop
            if let m { meeting = m }
            tasks = t
        }
    }

    private func turn(_ g: TurnGroup) -> some View {
        let isMatch = !findText.isEmpty && matchSet.contains(g.id)
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
        // All the SQLite reads + transcript grouping happen OFF the main thread (Store is Sendable), then
        // we assign state on the main actor — so opening a long call doesn't freeze the sidebar/navigation.
        let store = env.store, id = meetingID
        let snap = await Task.detached { MeetingDetailView.buildSnapshot(store: store, meetingID: id) }.value
        meeting = snap.meeting
        tasks = snap.tasks
        people = snap.people
        noteLines = snap.noteLines
        groups = snap.groups
        recomputeMatches()
        recomputeHighlight()
    }

    nonisolated static func buildSnapshot(store: Store, meetingID: String) -> LoadSnapshot {
        var snap = LoadSnapshot(meeting: try? store.meeting(id: meetingID))
        snap.tasks = (try? store.tasks(meetingID: meetingID)) ?? []
        let utts = (try? store.utterances(meetingID: meetingID)) ?? []
        if snap.meeting?.source == "gmeet_gemini" {
            snap.noteLines = utts.isEmpty
                ? ((try? store.transcript(meetingID: meetingID)) ?? []).map(\.text)
                : utts.map(\.text)
        } else {
            snap.people = ((try? store.entities(meetingID: meetingID)) ?? [])
                .filter { $0.kind == .person && $0.count >= 2 }.prefix(10).map { $0 }
        }
        let rows: [(speaker: String, t: Double?, inferred: Bool, text: String)]
        if utts.isEmpty {
            rows = ((try? store.transcript(meetingID: meetingID)) ?? [])
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
        snap.groups = result
        return snap
    }
}
