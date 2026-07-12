import SwiftUI
import CallBrainCore

/// Perfection plan Task 8.2 — People: everyone who shows up across your calls, with a detail
/// page (their calls, their open tasks, and one-tap "Ask about them" pre-scoped chat).
struct PeopleView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var peopleState: LoadState<[Store.PersonSummary]> = .idle
    @State private var selected: Store.PersonSummary?
    // Four-state so a read FAILURE shows a retry instead of spinning "Loading…" forever (audit).
    @State private var detailState: LoadState<Store.PersonDetail> = .idle

    var body: some View {
        HStack(spacing: 0) {
            peopleList
                .frame(width: 260)
            Divider()
            if let selected {
                personDetail(selected)
            } else {
                ContentUnavailableView("Pick a person", systemImage: "person.crop.circle",
                                       description: Text("Everyone from your calls shows up on the left."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("People")
        .task { await load() }
    }

    private func load() async {
        peopleState = .loading
        let store = env.store
        let (always, keywords) = peopleExclusions()
        let blocked = NotPeople.current()   // user-taught "not a person" entries
        let state = await LoadState.load {
            try store.people(excluding: always, excludingUngrounded: keywords, blocklist: blocked)
        }
        withAnimation(Theme.springy) { peopleState = state }
        if selected == nil, case .loaded(let p) = state, let first = p.first { select(first) }
    }

    /// Right-click → "Not a person": teach the app to never list this name again (persisted across launches),
    /// and drop it from the roster immediately. Undoable in Settings › People.
    private func markNotPerson(_ p: Store.PersonSummary) {
        NotPeople.add(p.name)
        if selected?.name == p.name { selected = nil; detailState = .idle }
        Task { await load() }
    }

    /// Two exclusion sets for the roster (lowercased; token-matched in Store.people):
    /// - `always`: the user themselves (name aliases) + their venture NAMES — never "other people on my calls".
    /// - `keywords`: venture keywords (product/domain terms like an AI product named "Pearl") — dropped, but
    ///   only for NON-grounded names, so a real diarized speaker who collides with a keyword still shows.
    private func peopleExclusions() -> (always: Set<String>, keywords: Set<String>) {
        var always = Set(FounderIdentity.aliases)
        var keywords = Set<String>()
        for v in env.ventures {
            always.insert(v.label.lowercased())
            for k in v.keywords { keywords.insert(k.lowercased()) }
        }
        return (always, keywords)
    }

    private func select(_ p: Store.PersonSummary) {
        selected = p
        detailState = .loading
        let store = env.store, name = p.name
        Task {
            let state = await LoadState.load { try store.personDetail(name: name) }
            if selected?.name == name { detailState = state }
        }
    }

    private var peopleList: some View {
        LoadStateView(state: peopleState, loadingLabel: "Loading people…",
                      failedLabel: "Couldn't load people.",
                      retry: { Task { await load() } }) { people in
            if people.isEmpty {
                ContentUnavailableView("No people yet", systemImage: "person.2",
                                       description: Text("People are recognized as calls are imported."))
            } else {
                ScrollView {
                    // Eager VStack (not LazyVStack): macOS 26 beachballs a scrolling LazyVStack
                    // (see macos26-lazyvstack-scroll-hang). Bounded people list → eager is safe.
                    VStack(spacing: 2) {
                        ForEach(people) { p in
                            Button { select(p) } label: { personRow(p) }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button(role: .destructive) { markNotPerson(p) } label: {
                                        Label("Not a person", systemImage: "person.slash")
                                    }
                                }
                        }
                    }
                    .padding(Space.s)
                }
            }
        }
        .background(Theme.surfaceSunken)
    }

    private func personRow(_ p: Store.PersonSummary) -> some View {
        let isSel = selected?.name == p.name
        return HStack(spacing: Space.m) {
            Avatar(name: p.name, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(p.name).font(.cbBody.weight(.medium)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Text("\(p.meetingCount) call\(p.meetingCount == 1 ? "" : "s") · last \(MeetingsView.friendlyDate(p.lastSeen))")
                    .font(.cbCaption).foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Space.s - 2).padding(.horizontal, Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).fill(isSel ? Theme.accentSoft : .clear))
        .contentShape(Rectangle())
    }

    private func personDetail(_ p: Store.PersonSummary) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: Space.l) {
                    Avatar(name: p.name, size: 52)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.name).font(.cbTitle).foregroundStyle(Theme.textPrimary)
                        Text("\(p.meetingCount) calls · \(p.mentions) mentions")
                            .font(.cbCallout).foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    Button {
                        // Pre-scoped chat: jump to Ask with a person question ready to send.
                        env.selectedTab = .ask
                        env.askChat.newChat()
                        env.pendingAskDraft = "What did \(p.name) say recently, and what do they owe me?"
                    } label: { Label("Ask about \(p.name.split(separator: " ").first.map(String.init) ?? p.name)", systemImage: CBIcon.ask) }
                        .buttonStyle(.borderedProminent).tint(Theme.accent)
                    Menu {
                        Button(role: .destructive) { markNotPerson(p) } label: {
                            Label("Not a person", systemImage: "person.slash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle").font(.system(size: 16))
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    .help("Not a person? Remove it from People and never list it again.")
                }

                // The header shows immediately from `selected`; only the data cards wait on the read —
                // and a failed read now offers Retry instead of an endless spinner.
                LoadStateView(state: detailState, loadingLabel: "Loading…",
                              failedLabel: "Couldn't load \(p.name)'s calls.",
                              fill: false, retry: { select(p) }) { detail in
                    VStack(alignment: .leading, spacing: 18) {
                        if !detail.openTasks.isEmpty {
                            VStack(alignment: .leading, spacing: Space.s) {
                                Text("Open tasks they own").font(.cbHeadline).foregroundStyle(Theme.textPrimary)
                                ForEach(detail.openTasks) { row in
                                    Button { env.openMeeting(row.item.meetingID) } label: {
                                        HStack(spacing: Space.s) {
                                            Circle().fill(Theme.accent).frame(width: 5, height: 5)
                                            Text(row.item.text).font(.cbCallout).foregroundStyle(Theme.textPrimary).lineLimit(1)
                                            Spacer()
                                            Text(row.meetingDate).font(.cbCaption).foregroundStyle(Theme.textTertiary)
                                            Image(systemName: "chevron.right").font(.cbCaption).foregroundStyle(Theme.textTertiary)
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .cbCard()
                        }

                        VStack(alignment: .leading, spacing: Space.s) {
                            Text("Their calls").font(.cbHeadline).foregroundStyle(Theme.textPrimary)
                            ForEach(detail.meetings) { m in
                                Button { env.openMeeting(m.id) } label: {
                                    HStack(spacing: Space.m) {
                                        Image(systemName: "waveform").font(.system(size: 14, weight: .medium))
                                            .foregroundStyle(Theme.textTertiary).frame(width: 18)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(m.displayTitle).font(.cbBody).foregroundStyle(Theme.textPrimary).lineLimit(1)
                                            Text(MeetingsView.friendlyDate(m.date)).font(.cbCaption).foregroundStyle(Theme.textSecondary)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right").font(.cbCaption).foregroundStyle(Theme.textTertiary)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain).cbHoverRow(radius: Radius.sm)
                                if m.id != detail.meetings.last?.id { Divider() }
                            }
                        }
                        .cbCard()
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}
