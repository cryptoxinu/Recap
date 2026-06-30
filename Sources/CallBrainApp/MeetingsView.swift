import SwiftUI
import CallBrainCore

struct MeetingsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var meetings: [Store.MeetingRow] = []
    @State private var query = ""
    @State private var categoryFilter: CallCategory?      // nil = all ventures
    @State private var dupCount = 0
    @State private var showDupReview = false
    @State private var pendingDelete: Store.MeetingRow?
    @State private var deleteError: String?
    // Navigation path (seedable for screenshot QA: CALLBRAIN_OPEN_MEETING=<id> opens straight to the workspace).
    @State private var path: [String] = {
        let id = ProcessInfo.processInfo.environment["CALLBRAIN_OPEN_MEETING"] ?? ""
        return id.isEmpty ? [] : [id]
    }()

    private var filtered: [Store.MeetingRow] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return meetings.filter { m in
            if let cat = categoryFilter {
                // An uncategorized call (still classifying) matches no specific venture filter.
                guard let stored = m.category, !stored.isEmpty, CallCategory(stored: stored) == cat else { return false }
            }
            guard !q.isEmpty else { return true }
            return m.displayTitle.lowercased().contains(q) || m.title.lowercased().contains(q)
                || m.source.lowercased().contains(q)
        }
    }

    private func count(_ cat: CallCategory) -> Int {
        meetings.filter { ($0.category?.isEmpty == false) && CallCategory(stored: $0.category) == cat }.count
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if meetings.isEmpty {
                    ContentUnavailableView("No meetings yet", systemImage: "calendar",
                                           description: Text("Import a transcript to get started."))
                } else {
                    VStack(spacing: 0) {
                        if dupCount > 0 {
                            dupBanner.transition(.move(edge: .top).combined(with: .opacity))
                        }
                        List(filtered) { m in
                            NavigationLink(value: m.id) { row(m).cbHoverRow() }
                                .contextMenu {
                                    Menu {
                                        ForEach(CallCategory.allCases, id: \.self) { c in
                                            Button { env.setCategoryManual(m.id, c); reload() } label: {
                                                Label(c.label, systemImage: CallCategory(stored: m.category) == c ? "checkmark" : "circle")
                                            }
                                        }
                                    } label: { Label("Category", systemImage: "tag") }
                                    Button(role: .destructive) { pendingDelete = m } label: {
                                        Label("Delete call…", systemImage: "trash")
                                    }
                                }
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) { pendingDelete = m } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                        }
                        .navigationDestination(for: String.self) { id in
                            MeetingWorkspaceView(meetingID: id)
                        }
                        .animation(Theme.springy, value: categoryFilter)
                        .animation(Theme.springy, value: query)
                    }
                }
            }
            .navigationTitle("Meetings")
            .searchable(text: $query, prompt: "Search calls")
            .toolbar { ToolbarItem(placement: .primaryAction) { categoryFilterMenu } }
        }
        .task {
            reload()
            env.backfillCategories()    // tag any calls that don't have a venture yet
            if ProcessInfo.processInfo.environment["CALLBRAIN_DUPREVIEW"] == "1" { showDupReview = true }
        }
        .onChange(of: env.titlesRevision) { reload() }   // live-refresh as AI titles land
        .sheet(isPresented: $showDupReview, onDismiss: reload) { DuplicateReviewView() }
        .confirmationDialog(
            pendingDelete.map { "Delete “\($0.title)”?" } ?? "Delete call?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete call", role: .destructive) {
                if let m = pendingDelete {
                    if env.deleteMeeting(m.id) {
                        path.removeAll { $0 == m.id }   // pop the workspace if this call is open (SME)
                        reload()
                    } else { deleteError = "Couldn't delete that call." }
                }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("This permanently removes the call, its transcript, tasks, and any chats about it. This can't be undone.")
        }
        .alert("Delete failed", isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })) {
            Button("OK", role: .cancel) { deleteError = nil }
        } message: { Text(deleteError ?? "") }
    }

    private var categoryFilterMenu: some View {
        Menu {
            Picker("Filter", selection: $categoryFilter) {
                Text("All ventures").tag(CallCategory?.none)
                ForEach(CallCategory.allCases, id: \.self) { c in
                    Text("\(c.label) (\(count(c)))").tag(CallCategory?.some(c))
                }
            }
        } label: {
            Label(categoryFilter?.label ?? "All ventures", systemImage: "line.3.horizontal.decrease.circle")
        }
    }

    private var dupBanner: some View {
        Button { showDupReview = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.on.rectangle.angled").foregroundStyle(.orange)
                Text("\(dupCount) possible duplicate\(dupCount == 1 ? "" : "s") found")
                    .font(.callout).foregroundStyle(.primary)
                Spacer()
                Text("Review").foregroundStyle(Theme.accent)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(.orange.opacity(0.1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func reload() {
        // Animate so AI titles/categories/summaries settle in (rows reorder, pills fade) instead of popping.
        withAnimation(Theme.springy) { meetings = env.recentMeetings() }
        // The duplicate scan is an N+1 query — run it OFF the main thread so it never freezes the list.
        let store = env.store
        Task {
            let c = await Task.detached { DuplicateScan.count(store) }.value
            withAnimation(Theme.springy) { dupCount = c }
        }
    }

    /// True when the AI gave the call a meaningful name that differs from its raw (often date-stamp) title.
    private func renamed(_ m: Store.MeetingRow) -> Bool {
        (m.aiTitle?.isEmpty == false) && m.aiTitle != m.title
    }

    private func row(_ m: Store.MeetingRow) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform.circle.fill").foregroundStyle(Theme.accent).font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(m.displayTitle).bold().lineLimit(1)                       // AI smart title
                if let s = m.aiSummary, !s.isEmpty {
                    Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                // Original title (when the AI renamed it) so a date-stamped call still shows its raw name.
                Text(renamed(m) ? "\(m.title) · \(sourceLabel(m.source))" : "\(m.date) · \(sourceLabel(m.source))")
                    .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer()
            if m.category != nil { CategoryTag(category: CallCategory(stored: m.category)) }
        }
        .padding(.vertical, 4)
    }

    private func sourceLabel(_ s: String) -> String {
        switch s {
        case "gmeet_gemini": "Google Meet notes"
        case "gmeet_local", "gmeet_cloud": "Recording"
        case "fireflies": "Fireflies"; case "fathom": "Fathom"; case "cluely": "Cluely"
        case "paste": "Pasted"; default: s
        }
    }
}

/// A small colored pill showing which venture a call belongs to.
struct CategoryTag: View {
    let category: CallCategory
    var body: some View {
        Text(category.label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Self.color(category).opacity(0.16), in: Capsule())
            .foregroundStyle(Self.color(category))
    }
    static func color(_ c: CallCategory) -> Color {
        switch c {
        case .ambient: .blue
        case .furtherHealth: .green
        case .other: .secondary
        }
    }
}
