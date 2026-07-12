import SwiftUI
import CallBrainCore

struct MeetingsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var meetings: [Store.MeetingRow] = []
    @State private var query = ""
    @State private var categoryFilter: String?            // nil = all ventures; else a Venture.id or "other"
    @State private var dupCount = 0
    @State private var showDupReview = false
    @State private var dupAutoCleanup = false    // banner "Clean up" jumps straight to the AI cleanup
    @State private var pendingDelete: Store.MeetingRow?
    @State private var deleteError: String?
    @State private var reloadSeq = 0                      // drops out-of-order off-main reloads
    @State private var reloadTask: Task<Void, Never>?     // cancels a superseded reload (no scan pile-up)
    @State private var didLoad = false                   // true after the first reload — no false "empty" flash
    @State private var categoryCounts: [String: Int] = [:]         // venture id ("other" incl.) → count
    @State private var durations: [String: Double] = [:]           // meetingID → seconds (Task 7.3)
    @State private var people: [String: [String]] = [:]            // meetingID → top names (Task 7.3)
    @State private var pendingRename: Store.MeetingRow?   // the call being renamed (drives the rename sheet)
    @State private var renameText = ""
    // Navigation path is ENV-owned (Task 7.3: the one canonical open-meeting route — palette,
    // Home, Tasks, Import all push through env.openMeeting). QA seeding moved to AppEnvironment.

    private var filtered: [Store.MeetingRow] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return meetings.filter { m in
            if let cat = categoryFilter {
                // Normalize a missing/empty/ORPHANED (venture-since-deleted) category to "other" so it's
                // caught by the Other pill, and counts + filtering always agree (audit #8/#9).
                guard effectiveCategory(m.category) == cat else { return false }
            }
            guard !q.isEmpty else { return true }
            return m.displayTitle.lowercased().contains(q) || m.title.lowercased().contains(q)
                || m.source.lowercased().contains(q)
        }
    }

    private func count(_ cat: String) -> Int { categoryCounts[cat] ?? 0 }

    /// The venture-filter buckets shown as pills / picker rows: one per configured venture, then "Other".
    private var filterBuckets: [(id: String, label: String)] {
        env.ventures.map { ($0.id, $0.label) } + [(kOtherVentureID, "Other")]
    }

    /// Normalize a stored category to a bucket that EXISTS in the current config: a known venture id stays
    /// itself; nil/empty AND any orphaned id (venture since deleted) fold into "other". Used by BOTH the
    /// filter and the counts so a pill's number always matches what it filters to (audit #8/#9).
    private func effectiveCategory(_ stored: String?) -> String {
        guard let s = stored, !s.isEmpty, env.ventures.contains(where: { $0.id == s }) else { return kOtherVentureID }
        return s
    }

    /// Today / Yesterday / This week / Earlier buckets, preserving recency order (Task 7.3).
    private var grouped: [(title: String, rows: [Store.MeetingRow])] {
        let today = TimeCode.ymd(Date())
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"; df.locale = Locale(identifier: "en_US_POSIX")
        func bucket(_ ymd: String) -> String {
            if ymd == today { return "Today" }
            guard let d = df.date(from: ymd), let t = df.date(from: today) else { return "Earlier" }
            let days = Calendar.current.dateComponents([.day], from: d, to: t).day ?? 999
            if days < 0 { return "Upcoming" }               // future-dated rows (gate LOW)
            if days == 1 { return "Yesterday" }
            if days < 7 { return "This week" }
            return "Earlier"
        }
        var order: [String] = []
        var groups: [String: [Store.MeetingRow]] = [:]
        for m in filtered {
            let b = bucket(m.date)
            if groups[b] == nil { order.append(b) }
            groups[b, default: []].append(m)
        }
        return order.map { (title: $0, rows: groups[$0] ?? []) }
    }

    /// One pass over meetings → per-venture counts (audit LOW: filterPill was re-filtering all rows once per
    /// pill on every body eval). Recomputed only when the meeting set changes, in reload().
    /// Per-bucket counts using the SAME normalization as the filter: every call lands in exactly one
    /// bucket (a known venture id, else "other"), so a pill's count always equals what it filters to.
    private static func computeCounts(_ meetings: [Store.MeetingRow], ventureIDs: Set<String>) -> [String: Int] {
        var m: [String: Int] = [:]
        for row in meetings {
            let stored = row.category ?? ""
            let bucket = (!stored.isEmpty && ventureIDs.contains(stored)) ? stored : kOtherVentureID
            m[bucket, default: 0] += 1
        }
        return m
    }

    var body: some View {
        @Bindable var env = env
        return NavigationStack(path: $env.meetingsPath) {
            Group {
                if meetings.isEmpty && !didLoad {
                    // Still loading — never flash "No meetings yet" before the async read returns (recon).
                    HStack(spacing: Space.s) {
                        ProgressView().controlSize(.small)
                        Text("Loading your calls…").font(.cbCallout).foregroundStyle(Theme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if meetings.isEmpty {
                    CBEmptyState(systemImage: "waveform",
                                 title: "No calls yet",
                                 message: "Import a transcript or record a call, and it'll show up here — then ask it anything.",
                                 actionTitle: "Import a transcript") { env.selectedTab = .imports }
                } else {
                    VStack(spacing: 0) {
                        if dupCount > 0 {
                            dupBanner.transition(.move(edge: .top).combined(with: .opacity))
                        }
                        if !env.ventures.isEmpty { categoryFilterBar }   // venture filter (only once ventures are configured)
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: Space.s, pinnedViews: [.sectionHeaders]) {
                                ForEach(grouped, id: \.title) { group in
                                    Section {
                                        ForEach(group.rows) { m in
                                            NavigationLink(value: m.id) { card(m) }
                                                .buttonStyle(.plain)
                                                .contextMenu {
                                                    Button { beginRename(m) } label: { Label("Rename…", systemImage: "pencil") }
                                                    Menu {
                                                        ForEach(filterBuckets, id: \.id) { b in
                                                            Button { Task { await env.setCategoryManual(m.id, b.id); reload() } } label: {
                                                                Label(b.label, systemImage: (m.category ?? kOtherVentureID) == b.id ? "checkmark" : "circle")
                                                            }
                                                        }
                                                    } label: { Label("Category", systemImage: "tag") }
                                                    Button(role: .destructive) { pendingDelete = m } label: {
                                                        Label("Delete call…", systemImage: "trash")
                                                    }
                                                }
                                        }
                                    } header: { groupHeader(group.title) }
                                }
                            }
                            .padding(.horizontal, Space.l).padding(.bottom, Space.l)
                            .frame(maxWidth: 880, alignment: .leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .navigationDestination(for: String.self) { id in
                            MeetingWorkspaceView(meetingID: id)
                        }
                        .animation(Theme.springy, value: categoryFilter)   // spring only on discrete pill selection
                        // (No spring on `query`: springing the whole List on every keystroke is janky — recon.)
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
        // Titles/categories changed — the call SET didn't, so refresh the list but SKIP the expensive
        // duplicate scan (audit MED: a category backfill bumps titlesRevision once per call → without this
        // every bump spawned a full recentMeetings + O(k²) DuplicateScan, a thundering herd on first launch).
        .onChange(of: env.titlesRevision) { reload(scanDupes: false) }
        .sheet(isPresented: $showDupReview, onDismiss: { reload() }) { DuplicateReviewView(autoCleanup: dupAutoCleanup) }
        .confirmationDialog(
            pendingDelete.map { "Delete “\($0.title)”?" } ?? "Delete call?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete call", role: .destructive) {
                guard let m = pendingDelete else { return }
                pendingDelete = nil
                Task { @MainActor in                     // cascade delete runs off-main (audit HIGH)
                    if await env.deleteMeetingAsync(m.id) {
                        env.meetingsPath.removeAll { $0 == m.id }   // pop the workspace if this call is open (SME)
                        reload()
                    } else { deleteError = "Couldn't delete that call." }
                }
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("This permanently removes the call, its transcript, tasks, and any chats about it. This can't be undone.")
        }
        .alert("Delete failed", isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })) {
            Button("OK", role: .cancel) { deleteError = nil }
        } message: { Text(deleteError ?? "") }
        .sheet(item: $pendingRename) { m in renameSheet(m) }
    }

    // MARK: - venture filter bar (always visible so filtering is one tap)

    private var categoryFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterPill("All", nil, meetings.count)
                ForEach(filterBuckets, id: \.id) { b in filterPill(b.label, b.id, count(b.id)) }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
    }

    private func filterPill(_ label: String, _ cat: String?, _ n: Int) -> some View {
        let selected = categoryFilter == cat
        return Button {
            withAnimation(Theme.springy) { categoryFilter = selected && cat != nil ? nil : cat }  // tap again = clear
        } label: {
            HStack(spacing: 5) {
                Text(label)
                Text("\(n)").font(.cbCaption.weight(.semibold)).opacity(0.75)
            }
            .font(.cbCallout.weight(selected ? .semibold : .regular))
            .padding(.horizontal, Space.m).padding(.vertical, Space.xs + 2)
            .background(selected ? Theme.accent : Theme.surface, in: Capsule())
            .foregroundStyle(selected ? Theme.onAccent : Theme.textPrimary)
            .overlay(Capsule().strokeBorder(selected ? Color.clear : Theme.hairline))
        }
        .buttonStyle(.plain)
    }

    // MARK: - rename

    private func beginRename(_ m: Store.MeetingRow) { renameText = m.displayTitle; pendingRename = m }

    private func renameSheet(_ m: Store.MeetingRow) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename call").font(.headline)
            TextField("Title", text: $renameText).textFieldStyle(.roundedBorder).frame(width: 380)
                .onSubmit { commitRename(m) }
            Text("The original title (“\(m.title)”) is kept — this is just what shows in your lists.")
                .font(.caption).foregroundStyle(.secondary).frame(width: 380, alignment: .leading)
            HStack {
                Spacer()
                Button("Cancel") { pendingRename = nil }
                Button("Save") { commitRename(m) }
                    .buttonStyle(.borderedProminent).tint(Theme.accent)
                    .disabled(renameText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
    }

    private func commitRename(_ m: Store.MeetingRow) {
        let t = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }   // Enter on a blank field must NOT clear the title (matches disabled Save)
        pendingRename = nil
        Task { await env.renameMeeting(m.id, to: t); reload() }
    }

    private var categoryFilterMenu: some View {
        Menu {
            Picker("Filter", selection: $categoryFilter) {
                Text("All ventures").tag(String?.none)
                ForEach(filterBuckets, id: \.id) { b in
                    Text("\(b.label) (\(count(b.id)))").tag(String?.some(b.id))
                }
            }
        } label: {
            let current = categoryFilter.map { VentureConfig.label(for: $0, in: env.ventures) } ?? "All ventures"
            Label(current, systemImage: "line.3.horizontal.decrease.circle")
        }
    }

    private var dupBanner: some View {
        HStack(spacing: Space.s) {
            Image(systemName: "rectangle.on.rectangle.angled").foregroundStyle(Theme.warning)
            Text("\(dupCount) possible duplicate\(dupCount == 1 ? "" : "s") found")
                .font(.cbCallout).foregroundStyle(Theme.textPrimary)
            Spacer()
            // One click: let the AI keep the richest copy of each call and combine the rest
            // (nothing deleted). The row itself still opens the manual review.
            Button { dupAutoCleanup = true; showDupReview = true } label: {
                Label("Clean up with AI", systemImage: "sparkles").font(.cbCaption.weight(.semibold))
            }
            .buttonStyle(.borderedProminent).tint(Theme.accent).controlSize(.small)
            .help("Keep the highest-quality copy of each call and combine the rest — nothing is deleted.")
            Button { dupAutoCleanup = false; showDupReview = true } label: {
                Text("Review").font(.cbCallout.weight(.medium)).foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Space.l).padding(.vertical, Space.s)
        .background(Theme.warningSoft)
        .contentShape(Rectangle())
        .onTapGesture { dupAutoCleanup = false; showDupReview = true }
    }

    private func reload(scanDupes: Bool = true) {
        // BOTH the meeting-list SELECT (up to 200 rows) and the N+1 duplicate scan run OFF the main thread
        // (audit HIGH — the list read was still synchronous on main). A sequence token drops a slower earlier
        // reload so results can't land out of order (last-issued wins), AND the prior reload Task is cancelled
        // so a burst of titlesRevision bumps can't pile up detached scans (audit MED). Animate so pills settle.
        let store = env.store
        reloadSeq += 1; let seq = reloadSeq
        reloadTask?.cancel()
        reloadTask = Task { @MainActor in
            let m = await Task.detached { (try? store.recentMeetings()) ?? [] }.value
            guard reloadSeq == seq, !Task.isCancelled else { return }
            let ids = m.map(\.id)
            let (durs, ppl) = await Task.detached {
                ((try? store.meetingDurations(ids: ids)) ?? [:], (try? store.meetingPeople(ids: ids)) ?? [:])
            }.value
            guard reloadSeq == seq, !Task.isCancelled else { return }
            withAnimation(Theme.springy) {
                meetings = m; categoryCounts = Self.computeCounts(m, ventureIDs: Set(env.ventures.map(\.id)))
                durations = durs; people = ppl
                didLoad = true
            }
            guard scanDupes else { return }   // title/category-only refresh → the duplicate set is unchanged
            let c = await Task.detached { DuplicateScan.count(store) }.value
            guard reloadSeq == seq, !Task.isCancelled else { return }
            withAnimation(Theme.springy) { dupCount = c }
        }
    }

    /// True when the AI gave the call a meaningful name that differs from its raw (often date-stamp) title.
    private func renamed(_ m: Store.MeetingRow) -> Bool {
        (m.aiTitle?.isEmpty == false) && m.aiTitle != m.title
    }

    /// A pinned section header (Today / This week / Earlier) in the eyebrow style.
    private func groupHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.cbCaption.weight(.semibold)).tracking(0.5)
            .foregroundStyle(Theme.textTertiary)
            .padding(.top, Space.l).padding(.bottom, Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.bg)
    }

    /// A rich call card (redesign the founder approved): venture-tinted tick, title + key-topics line,
    /// per-participant colored avatars, duration/source meta, and the venture tag — scannable at a glance.
    private func card(_ m: Store.MeetingRow) -> some View {
        HStack(alignment: .top, spacing: Space.m) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(ventureTick(m)).frame(width: 3).frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                    Text(m.displayTitle).font(.cbHeadline).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    Spacer(minLength: Space.s)
                    Text(metaLine(m)).font(.cbCaption).foregroundStyle(Theme.textTertiary)
                        .lineLimit(1).fixedSize()   // the date · duration · source never truncates
                }
                if let s = m.aiSummary, !s.isEmpty {           // the AI one-liner reads like the call's key topics
                    Text(s).font(.cbCallout).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
                HStack(spacing: Space.s) {
                    cardAvatars(m)
                    Spacer(minLength: 0)
                    if let cat = m.category, !cat.isEmpty, cat != kOtherVentureID {
                        CategoryTag(id: cat, ventures: env.ventures)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(Space.m + 2)
        .background(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).strokeBorder(Theme.hairline))
        .contentShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .cbCardHoverLift()
    }

    /// Venture-tinted left tick (falls back to the brand accent when a call has no venture yet).
    private func ventureTick(_ m: Store.MeetingRow) -> Color {
        guard let cat = m.category, !cat.isEmpty, cat != kOtherVentureID else { return Theme.accent }
        return CategoryTag.color(cat, ventures: env.ventures)
    }

    /// Overlapping participant avatars, one curated hue each (+N when there are more).
    @ViewBuilder private func cardAvatars(_ m: Store.MeetingRow) -> some View {
        if let names = people[m.id], !names.isEmpty {
            HStack(spacing: 6) {
                HStack(spacing: -6) {
                    ForEach(names.prefix(3), id: \.self) { name in
                        let hue = Theme.speakerColor(name)
                        Text(Self.initials(name))
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(hue)
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(hue.opacity(0.18)))
                            .overlay(Circle().strokeBorder(Theme.surface, lineWidth: 2))
                    }
                }
                if names.count > 3 {
                    Text("+\(names.count - 3)").font(.cbCaption).foregroundStyle(Theme.textTertiary)
                }
            }
            .help(names.joined(separator: ", "))
        }
    }

    /// "Mon, Jun 30 · 42 min · Google Meet notes" — friendly, scannable, no raw IDs.
    private func metaLine(_ m: Store.MeetingRow) -> String {
        var parts = [Self.friendlyDate(m.date)]
        if let d = durations[m.id], d >= 60 { parts.append("\(Int(d / 60)) min") }
        parts.append(sourceLabel(m.source))
        return parts.joined(separator: " · ")
    }

    /// "Today" / "Yesterday" / "Mon, Jun 30" / "Jun 30, 2025" from a YMD string.
    static func friendlyDate(_ ymd: String, today: String = TimeCode.ymd(Date())) -> String {
        if ymd == today { return "Today" }
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"; df.locale = Locale(identifier: "en_US_POSIX")
        guard let d = df.date(from: ymd), let t = df.date(from: today) else { return ymd }
        let days = Calendar.current.dateComponents([.day], from: d, to: t).day ?? 999
        if days == 1 { return "Yesterday" }
        let out = DateFormatter()
        out.dateFormat = (0..<180).contains(days) ? "EEE, MMM d" : "MMM d, yyyy"   // future → full date (gate LOW)
        return out.string(from: d)
    }

    static func initials(_ name: String) -> String {
        let parts = name.split(separator: " ")
        let chars = parts.prefix(2).compactMap(\.first)
        return chars.isEmpty ? "?" : String(chars).uppercased()
    }

    private func sourceLabel(_ s: String) -> String {
        switch s {
        case "gmeet_gemini": "Google Meet notes"
        case "gmeet_captions": "Meet captions"
        case "gmeet_local", "gmeet_cloud": "Recording"
        case "fireflies": "Fireflies"; case "fathom": "Fathom"; case "cluely": "Cluely"
        case "paste": "Pasted"; default: s
        }
    }
}

/// A small colored pill showing which venture a call belongs to. `id` is the stored category (a
/// Venture.id); label + tint resolve from the user's configured ventures.
struct CategoryTag: View {
    let id: String
    let ventures: [Venture]
    var body: some View {
        let c = Self.color(id, ventures: ventures)
        Text(VentureConfig.label(for: id, in: ventures))
            .font(.cbCaption.weight(.semibold))
            .padding(.horizontal, Space.s).padding(.vertical, 3)
            .background(c.opacity(0.16), in: Capsule())
            .foregroundStyle(c)
    }
    /// Curated venture tint: the venture's custom color if set, else a stable palette hue by its
    /// position; "other"/unknown → secondary text color.
    static func color(_ id: String, ventures: [Venture]) -> Color {
        guard id != kOtherVentureID, let idx = ventures.firstIndex(where: { $0.id == id }) else {
            return Theme.textSecondary
        }
        if let hex = ventures[idx].colorHex, let c = Color(hex: hex) { return c }
        return Theme.venturePalette[idx % Theme.venturePalette.count]
    }
}
