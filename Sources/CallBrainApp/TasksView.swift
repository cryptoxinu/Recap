import SwiftUI
import CallBrainCore

/// The standing "what do I owe" view (Phase 4) — every action item lifted from a meeting, grouped by
/// status, with owner chips, a one-tap complete, and a link back to the source call.
struct TasksView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var rows: [Store.TaskRow] = []
    @State private var filter: Filter = .open
    @State private var openMeetingID: String?
    @State private var tidying = false
    @State private var tidySummary: String?

    enum Filter: String, CaseIterable, Identifiable { case open = "Open", done = "Done", all = "All"; var id: String { rawValue } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Text("Tasks").font(.title2).bold()
                    Spacer()
                    Button { tidy() } label: {
                        HStack(spacing: 5) {
                            if tidying { ProgressView().controlSize(.small) }
                            else { Image(systemName: "sparkles") }
                            Text(tidying ? "Tidying…" : "Tidy with AI")
                        }
                    }
                    .buttonStyle(.borderedProminent).tint(Theme.accent)
                    .disabled(tidying)
                    .help("Look across every call: reword tasks, mark done ones complete, merge duplicates, and add anything missing.")
                    Picker("", selection: $filter) {
                        ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).fixedSize()
                }
                if let s = tidySummary {
                    Label(s, systemImage: "checkmark.seal.fill")
                        .font(.callout).foregroundStyle(Theme.accent)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.accent.opacity(0.1)))
                }
                if rows.isEmpty {
                    emptyState
                } else {
                    ForEach(grouped, id: \.0) { owner, items in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(owner).font(.subheadline.bold()).foregroundStyle(Theme.accent)
                            VStack(spacing: 0) {
                                ForEach(items) { row in
                                    TaskRowView(row: row,
                                                onToggle: { toggle(row) },
                                                onOpen: { openMeetingID = row.item.meetingID })
                                    if row.id != items.last?.id { Divider() }
                                }
                            }
                            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.cardFill))
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hairline))
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .navigationTitle("Tasks")
        .task(id: filter) { load() }
        .sheet(item: $openMeetingID) { id in
            NavigationStack {
                MeetingDetailView(meetingID: id)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { openMeetingID = nil } } }
            }
            .frame(minWidth: 720, minHeight: 600)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "checklist").font(.system(size: 38)).foregroundStyle(Theme.accent.opacity(0.7))
            Text(filter == .done ? "No completed tasks yet." : "No action items yet")
                .font(.headline)
            Text("Import a meeting with notes (e.g. a Google-Meet “Notes by Gemini” doc) and CallBrain "
                 + "pulls out who owes what — automatically.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 60)
    }

    /// Group by owner ("Unassigned" last), preserving the store's date ordering within a group.
    private var grouped: [(String, [Store.TaskRow])] {
        var order: [String] = []
        var map: [String: [Store.TaskRow]] = [:]
        for r in rows {
            let key = r.item.owner?.isEmpty == false ? r.item.owner! : "Unassigned"
            if map[key] == nil { order.append(key) }
            map[key, default: []].append(r)
        }
        return order.sorted { ($0 == "Unassigned" ? 1 : 0, $0) < ($1 == "Unassigned" ? 1 : 0, $1) }
                    .map { ($0, map[$0]!) }
    }

    private func load() {
        let status: ActionItem.Status? = filter == .all ? nil : (filter == .open ? .open : .done)
        rows = (try? env.store.tasks(status: status)) ?? []
    }

    private func tidy() {
        guard !tidying else { return }
        tidying = true; tidySummary = nil
        Task {
            let result = await env.reconcileTasks()
            tidying = false
            load()
            if let r = result {
                if r.reworded + r.completed + r.deduped + r.added == 0 {
                    tidySummary = "Your task list is already tidy — nothing to change."
                } else {
                    var parts: [String] = []
                    if r.reworded > 0 { parts.append("reworded \(r.reworded)") }
                    if r.added > 0 { parts.append("added \(r.added)") }
                    if r.completed > 0 { parts.append("marked \(r.completed) done") }
                    if r.deduped > 0 { parts.append("merged \(r.deduped) duplicate\(r.deduped == 1 ? "" : "s")") }
                    tidySummary = "Tidied: " + parts.joined(separator: " · ") + "."
                }
            } else {
                tidySummary = "Couldn't reach the AI to tidy tasks — try again."
            }
        }
    }

    private func toggle(_ row: Store.TaskRow) {
        let next: ActionItem.Status = row.item.status == .open ? .done : .open
        try? env.store.setTaskStatus(id: row.item.id, next)
        load()
        env.refreshReminders()   // keep the daily reminder count fresh
    }
}

private struct TaskRowView: View {
    let row: Store.TaskRow
    let onToggle: () -> Void
    let onOpen: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onToggle) {
                Image(systemName: row.item.status == .done ? "checkmark.circle.fill" : "circle")
                    .font(.title3).foregroundStyle(row.item.status == .done ? .green : .secondary)
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.item.text)
                    .strikethrough(row.item.status == .done, color: .secondary)
                    .foregroundStyle(row.item.status == .done ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: onOpen) {
                    Text("\(row.meetingTitle) · \(row.meetingDate)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(12)
    }
}
