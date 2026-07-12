import SwiftUI
import CallBrainCore

/// Perfection plan Task 7.1b — the ⌘K palette. A floating overlay (not a sheet — sheets steal
/// focus rituals) with as-you-type universal search over meetings/moments/tasks/chats, keyboard
/// navigation, and Enter routing to the exact thing.
struct CommandPalette: View {
    @Environment(AppEnvironment.self) private var env
    @State private var query = ""
    @State private var results = Store.UniversalResults()
    @State private var selection = 0
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var fieldFocused: Bool

    /// One flattened, ordered row list so ↑↓/Enter are trivial.
    private enum Hit: Identifiable {
        case meeting(Store.MeetingRow)
        case moment(Store.ChunkHit)
        case task(Store.TaskRow)
        case chat(Conversation)
        case action(PaletteAction)       // "Do" — jump AND run: Ask AI, Record, Import
        var id: String {
            switch self {
            case .meeting(let m): "m|\(m.id)"
            case .moment(let c): "c|\(c.chunkID)"
            case .task(let t): "t|\(t.item.id)"
            case .chat(let c): "h|\(c.id)"
            case .action(let a): a.id
            }
        }
    }

    /// A runnable command from the palette (the "spine" doesn't just find things — it does them).
    enum PaletteAction: Identifiable, Hashable {
        case ask(String), record, importFiles
        var id: String {
            switch self { case .ask(let q): "act|ask|\(q)"; case .record: "act|rec"; case .importFiles: "act|imp" }
        }
        var title: String {
            switch self {
            case .ask(let q): "Ask AI — \u{201C}\(q)\u{201D}"
            case .record: "Record a meeting"
            case .importFiles: "Import a file…"
            }
        }
        var icon: String {
            switch self { case .ask: CBIcon.ask; case .record: "record.circle"; case .importFiles: "tray.and.arrow.down" }
        }
    }

    /// Query-dependent commands — shown once you've typed something (the "Ask AI" one carries your query).
    private var actions: [PaletteAction] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        return [.ask(q), .record, .importFiles]
    }

    private var hits: [Hit] {
        results.meetings.map(Hit.meeting) + results.moments.map(Hit.moment)
            + results.tasks.map(Hit.task) + results.chats.map(Hit.chat)
            + actions.map(Hit.action)
    }

    var body: some View {
        ZStack {
            // Click-away scrim.
            Color.black.opacity(0.25).ignoresSafeArea()
                .onTapGesture { env.paletteShown = false }
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search calls, moments, tasks, chats…", text: $query)
                        .textFieldStyle(.plain)
                        .font(.title3)
                        .focused($fieldFocused)
                        .onSubmit { open(selection) }
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.tertiary)
                    }
                }
                .padding(14)
                Divider()
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    paletteHint
                } else if hits.isEmpty {
                    ContentUnavailableView.search(text: query).frame(maxHeight: 200)
                } else {
                    resultsList
                }
            }
            .frame(width: 640)
            .frame(maxHeight: 440)
            .fixedSize(horizontal: false, vertical: true)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.22), radius: 20, y: 8)
            .padding(.top, 90)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .onAppear { fieldFocused = true }
        .onChange(of: query) { _, q in
            searchTask?.cancel()
            let store = env.store
            searchTask = Task {
                try? await Task.sleep(for: .milliseconds(140))   // as-you-type debounce
                guard !Task.isCancelled else { return }
                let r = await Task.detached { (try? store.searchEverything(q)) ?? Store.UniversalResults() }.value
                guard !Task.isCancelled else { return }
                results = r
                selection = 0
            }
        }
        .onExitCommand { env.paletteShown = false }             // Esc
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.downArrow) { move(1); return .handled }
    }

    private var paletteHint: some View {
        VStack(spacing: Space.xs + 2) {
            Text("Type to search everything").font(.cbCallout).foregroundStyle(Theme.textSecondary)
            Text("↑↓ to choose · Return to open · Esc to close").font(.cbCaption).foregroundStyle(Theme.textTertiary)
        }
        .padding(.vertical, Space.xl + 4)
        .frame(maxWidth: .infinity)
    }

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    section("Meetings", results.meetings.map(Hit.meeting))
                    section("Moments", results.moments.map(Hit.moment))
                    section("Tasks", results.tasks.map(Hit.task))
                    section("Chats", results.chats.map(Hit.chat))
                    section("Do", actions.map(Hit.action))
                }
                .padding(8)
            }
            .onChange(of: selection) { _, sel in
                if hits.indices.contains(sel) { proxy.scrollTo(hits[sel].id) }
            }
        }
    }

    @ViewBuilder private func section(_ title: String, _ items: [Hit]) -> some View {
        if !items.isEmpty {
            Text(title.uppercased())
                .font(.cbFootnote.weight(.semibold)).foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, Space.s).padding(.top, Space.s)
            ForEach(items) { hit in
                let idx = hits.firstIndex(where: { $0.id == hit.id }) ?? 0
                row(hit)
                    .padding(.horizontal, Space.m).padding(.vertical, Space.s - 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(idx == selection ? Theme.accentSoft : .clear,
                                in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                    .contentShape(Rectangle())
                    .onTapGesture { selection = idx; open(idx) }
                    .id(hit.id)
            }
        }
    }

    /// One consistent row grammar — leading glyph (one calm tint), a single rowTitle token, a quiet subtitle.
    @ViewBuilder private func row(_ hit: Hit) -> some View {
        switch hit {
        case .meeting(let m):
            paletteRow("waveform", title: Text(m.displayTitle), subtitle: MeetingsView.friendlyDate(m.date))
        case .moment(let c):
            paletteRow("quote.opening", top: true,
                       title: Text(highlighted(c.text)), titleLines: 2,
                       subtitle: "\(c.speaker ?? "Unknown")\(c.tStart.map { " · \(TimeCode.mmss($0))" } ?? "")")
        case .task(let t):
            paletteRow(t.item.status == .done ? "checkmark.circle.fill" : "circle",
                       tint: t.item.status == .done ? Theme.accent : Theme.textTertiary,
                       title: Text(t.item.text),
                       subtitle: "\(t.item.owner ?? "Unassigned") · \(t.meetingDate)")
        case .chat(let c):
            paletteRow("bubble.left", title: Text(c.title))
        case .action(let a):
            paletteRow(a.icon, tint: Theme.accent, title: Text(a.title))   // accent = a runnable command
        }
    }

    private func paletteRow(_ icon: String, top: Bool = false, tint: Color = Theme.textTertiary,
                            title: Text, titleLines: Int = 1, subtitle: String? = nil) -> some View {
        HStack(alignment: top ? .top : .center, spacing: Space.m) {
            Image(systemName: icon).foregroundStyle(tint).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                title.font(.cbBody).foregroundStyle(Theme.textPrimary).lineLimit(titleLines)
                if let subtitle {
                    Text(subtitle).font(.cbCaption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
            }
        }
    }

    /// Accent-highlight EVERY occurrence of the query inside a snippet (was only the first match).
    private func highlighted(_ text: String) -> AttributedString {
        var a = AttributedString(text)
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return a }
        var cursor = a.startIndex
        while cursor < a.endIndex, let r = a[cursor...].range(of: q, options: .caseInsensitive) {
            a[r].font = .cbBody.weight(.bold)
            a[r].foregroundColor = Theme.accent
            cursor = r.upperBound
        }
        return a
    }

    private func move(_ delta: Int) {
        guard !hits.isEmpty else { return }
        selection = max(0, min(hits.count - 1, selection + delta))
    }

    private func open(_ idx: Int) {
        guard hits.indices.contains(idx) else { return }
        let hit = hits[idx]
        env.paletteShown = false
        switch hit {
        case .meeting(let m): env.openMeeting(m.id)
        case .moment(let c): env.openMeeting(c.meetingID, focusChunkID: c.chunkID)
        case .task(let t):
            // Open the task's SOURCE call (at its grounding chunk when known), like the other hit
            // types — the old `.task` case discarded the row and just switched tabs (audit G3 MED).
            if let cid = t.item.sourceChunkID { env.openMeeting(t.item.meetingID, focusChunkID: cid) }
            else { env.openMeeting(t.item.meetingID) }
        case .chat(let c):
            env.selectedTab = .ask
            env.pendingOpenChatID = c.id
        case .action(let a):
            switch a {
            case .ask(let q):
                env.selectedTab = .ask
                env.askChat.newChat()
                env.pendingAskDraft = q            // pre-fills + focuses the composer; you hit ⏎ to send
                env.composerFocusRequest &+= 1
            case .record:      env.recordSheetShown = true
            case .importFiles: env.selectedTab = .imports
            }
        }
    }
}
