import SwiftUI
import CallBrainCore

/// The standing "what do I owe" view (Phase 4) — every action item lifted from a meeting, grouped by
/// status, with owner chips, a one-tap complete, and a link back to the source call.
struct TasksView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var rows: [Store.TaskRow] = []
    /// raw owner → canonical display name (folds "Sam"/"Samuel Ortiz" and Whisper's mis-heard surname
    /// spellings into one person). Rebuilt on each load; the biggest fix for the "it's all noise" feel.
    @State private var canon: [String: String] = [:]
    @State private var filter: Filter = .open
    @State private var scope: Scope = .mine           // this app is only for the founder → lead with THEIR to-dos
    @State private var tidying = false
    @State private var tidySummary: String?
    @State private var tidyTask: Task<Void, Never>?     // the in-flight Tidy run (Cancel calls .cancel())
    @State private var cancelRequested = false          // Cancel pressed → revert anything applied
    @State private var tidyFailed = false               // last summary was an error (banner icon/colour)
    @State private var reviewingAI = false   // "Have AI review" in-flight
    /// Name/task filter (Phase 2) — folded into `regroup()` so it's cached, never a per-body filter.
    @State private var query = ""
    /// Which owner sections are expanded. "You" starts open; teammates start collapsed so "Everyone" reads
    /// as a short people+counts list you expand to drill into. A live search shows every matching section.
    @State private var expanded: Set<String> = ["You"]
    // Tidy uses cloud AI, so it's disabled in local-only mode (audit: reconcileTasks returns nil there,
    // which the UI otherwise mis-renders as a retryable "couldn't reach the AI" error). (from People/Settings branch)
    @AppStorage(AppEnvironment.localOnlyKey) private var localOnly = false
    @State private var loadSeq = 0                    // drops out-of-order off-main task reloads
    @State private var didLoad = false                // true after first load — no false "empty" flash
    /// The grouped, scope-filtered rows the list renders — CACHED (recomputed in load() + on scope change),
    /// never a computed property in `body`. A computed `grouped` re-ran the ~660-alloc filter+group pass on
    /// every body invalidation; caching keeps scope/filter switches snappy without the (scroll-hanging)
    /// LazyVStack.
    @State private var groupedRows: [(String, [Store.TaskRow])] = []

    enum Filter: String, CaseIterable, Identifiable { case open = "Open", done = "Done", all = "All"; var id: String { rawValue } }
    enum Scope: String, CaseIterable, Identifiable { case mine = "For you", everyone = "Everyone"; var id: String { rawValue } }

    var body: some View {
        ScrollView {
            // EAGER VStack — a *scrolling* LazyVStack-in-ScrollView beachballs on macOS 26
            // (macos26-lazyvstack-scroll-hang; already reverted in PeopleView/LiveAssistantView). My earlier
            // LazyVStack "fix" for the scope-switch freeze traded it for a continuous scroll pinwheel. The
            // set is bounded (Store.tasks limit 500) → eager is safe. The scope-switch cost is instead
            // solved by CACHING the grouping in `groupedRows` (recomputed off the render path in
            // load()/onChange), not by lazy placement.
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: Space.s) {
                    Text("Tasks").font(.cbTitle).foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Button { tidy() } label: {
                        HStack(spacing: 5) {
                            if tidying { ProgressView().controlSize(.small) }
                            else { Image(systemName: CBIcon.premium) }
                            Text(tidying ? "Tidying…" : "Tidy with AI")
                        }
                    }
                    .buttonStyle(.borderedProminent).tint(Theme.accent)
                    .disabled(tidying || localOnly)
                    .help(localOnly
                          ? "Tidy uses cloud AI — turn off Local-only mode in Settings to use it."
                          : "Look across every call: reword tasks, mark done ones complete, merge duplicates, and add anything missing.")
                    Picker("", selection: $scope) {
                        ForEach(Scope.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).fixedSize()
                    .help("“For you” shows what YOU need to do (including org-wide items); “Everyone” shows all owners.")
                    Picker("", selection: $filter) {
                        ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).fixedSize()
                }
                // Live count — immediate, unmistakable feedback that the For-you/Everyone toggle changed
                // the set (the "You" section is pinned on top in BOTH scopes, so without this the switch
                // can look like nothing happened when the teammate sections are below the fold).
                if didLoad {
                    Text(scopeSummary(count: groupedRows.reduce(0) { $0 + $1.1.count }))
                        .font(.cbCaption).foregroundStyle(Theme.textSecondary)
                }
                if !env.taskCompletionReviews.isEmpty {
                    completionReviewBanner.transition(.move(edge: .top).combined(with: .opacity))
                }
                // Live progress while Tidy runs — determinate bar + a real Cancel (Part 2/3, 2026-07-11).
                if tidying, let p = env.tidyProgress {
                    HStack(alignment: .center, spacing: Space.m) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Tidying with AI — \(p.phase)").font(.cbCallout).foregroundStyle(Theme.textPrimary)
                            if p.total > 1 {
                                ProgressView(value: Double(min(p.done, p.total)), total: Double(p.total)).tint(Theme.accent)
                                Text("Reviewed \(p.done) of \(p.total) call\(p.total == 1 ? "" : "s")")
                                    .font(.cbCaption).foregroundStyle(Theme.textSecondary)
                            } else {
                                ProgressView().controlSize(.small)
                            }
                        }
                        Button("Cancel", role: .cancel) { cancelTidy() }.buttonStyle(.bordered)
                    }
                    .padding(Space.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).fill(Theme.accentSoft))
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                if let s = tidySummary, !tidying {
                    HStack(alignment: .center, spacing: Space.s) {
                        Label(s, systemImage: tidyFailed ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                            .font(.cbCallout).foregroundStyle(tidyFailed ? Theme.danger : Theme.accent)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        // One-tap full revert of the last Tidy (Part 3): "in case I didn't want to run it."
                        if !tidyFailed, env.lastTidyUndo != nil {
                            Button { undoLastTidy() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                                .buttonStyle(.bordered)
                        }
                    }
                    .padding(Space.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).fill(tidyFailed ? Theme.danger.opacity(0.10) : Theme.accentSoft))
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                if groupedRows.isEmpty && !didLoad {
                    HStack(spacing: Space.s) {
                        ProgressView().controlSize(.small)
                        Text("Loading your tasks…").font(.cbCallout).foregroundStyle(Theme.textSecondary)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 60)
                } else if groupedRows.isEmpty {
                    emptyState.transition(.opacity)
                } else {
                    ForEach(groupedRows, id: \.0) { owner, items in
                        let show = isExpanded(owner)
                        VStack(alignment: .leading, spacing: Space.s) {
                            // Collapsible header: chevron + name + open count. "You" open by default;
                            // teammates collapsed → "Everyone" is a short scannable people+counts list.
                            Button { toggleExpanded(owner) } label: {
                                HStack(spacing: 7) {
                                    Image(systemName: show ? "chevron.down" : "chevron.right")
                                        .font(.cbCaption.weight(.semibold)).foregroundStyle(Theme.textTertiary)
                                        .frame(width: 10)
                                    Text(owner).font(.cbCallout.weight(.semibold)).foregroundStyle(Theme.accent)
                                    Text("\(items.count)").font(.cbCaption.weight(.semibold))
                                        .foregroundStyle(Theme.textTertiary)
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            if show {
                                VStack(spacing: 0) {
                                    ForEach(items) { row in
                                        TaskRowView(row: row,
                                                    onToggle: { toggle(row) },
                                                    onOpen: { env.openMeeting(row.item.meetingID) })
                                        if row.id != items.last?.id { Divider() }
                                    }
                                }
                                .background(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).fill(Theme.surface))
                                .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).strokeBorder(Theme.hairline))
                            }
                        }
                    }
                }
            }
            .padding(Space.xl)
            .frame(maxWidth: 900, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .navigationTitle("Tasks")
        .searchable(text: $query, placement: .toolbar, prompt: "Filter by name or task")
        .task(id: filter) { load() }
        .onChange(of: scope) { regroup() }   // re-filter the ALREADY-loaded rows (no DB reload) — cheap, off render path
        .onChange(of: query) { regroup() }   // name/task search — same cached path, not per-body
        .onChange(of: env.titlesRevision) { load() }   // a background auto-complete (Phase 4) marked tasks done → refresh
        .task {   // Screenshot QA: CALLBRAIN_TIDY=1 auto-runs the AI reconcile once.
            if ProcessInfo.processInfo.environment["CALLBRAIN_TIDY"] == "1", tidySummary == nil { tidy() }
        }
    }

    /// Ambiguous "this task looks done from a recent call" suggestions (Phase 5). Per-item ✓/✗, plus
    /// "Have AI review" to clear the truly-done ones in one tap. HIGH-confidence completions never land here
    /// (they auto-complete); this is only the cases we won't guess on.
    private var completionReviewBanner: some View {
        let reviews = env.taskCompletionReviews
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.badge.questionmark").foregroundStyle(Theme.accent)
                Text("\(reviews.count) task\(reviews.count == 1 ? "" : "s") may be done from recent calls")
                    .font(.cbCallout.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 0)
                if reviewingAI {
                    ProgressView().controlSize(.small)
                    Text("AI reviewing…").font(.cbCaption).foregroundStyle(.secondary)
                } else {
                    Button { reviewWithAI() } label: { Label("Have AI review", systemImage: CBIcon.premium).font(.cbCaption) }
                        .buttonStyle(.borderedProminent).tint(Theme.accent).controlSize(.small)
                }
                Button("Dismiss all") { withAnimation(Theme.quick) { env.dismissAllTaskCompletions() } }
                    .buttonStyle(.plain).font(.cbCaption).foregroundStyle(.secondary)
            }
            ForEach(reviews.prefix(6)) { r in
                HStack(spacing: 8) {
                    Text(r.taskText).font(.cbCallout).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    Text("· from \(r.meetingTitle)").font(.cbCaption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                    Button { withAnimation(Theme.quick) { env.confirmTaskCompletion(r.id) } } label: {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
                    }.buttonStyle(.plain).help("Mark done")
                    Button { withAnimation(Theme.quick) { env.dismissTaskCompletion(r.id) } } label: {
                        Image(systemName: "xmark.circle").foregroundStyle(.secondary)
                    }.buttonStyle(.plain).help("Not done — keep it open")
                }
            }
            if reviews.count > 6 {
                Text("+ \(reviews.count - 6) more — use “Have AI review”").font(.cbCaption).foregroundStyle(.tertiary)
            }
        }
        .padding(Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).fill(Theme.accentSoft))
        .overlay(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).strokeBorder(Theme.hairline))
    }

    private func reviewWithAI() {
        guard !reviewingAI else { return }
        reviewingAI = true
        Task {
            _ = await env.reviewTaskCompletionsWithAI()
            reviewingAI = false
            load()   // reflect the AI-confirmed completions
        }
    }

    private var emptyState: some View {
        VStack(spacing: Space.m) {
            Image(systemName: "checklist").font(.system(size: 30, weight: .light)).foregroundStyle(Theme.textTertiary)
            // If there ARE tasks but none are the founder's, say so (rather than the import-your-first pitch).
            Text(scope == .mine && !rows.isEmpty ? "Nothing here is assigned to you."
                 : filter == .done ? "No completed tasks yet." : "No action items yet")
                .font(.cbHeadline).foregroundStyle(Theme.textPrimary)
            // Branch the body on filter too — a user with open tasks who checks the Done tab shouldn't be
            // told to go import their first meeting (that onboarding pitch only fits an actually-empty list).
            Text(filter == .done
                 ? "Tasks you mark complete will collect here."
                 : "Import a meeting with notes (e.g. a Google-Meet “Notes by Gemini” doc) and Recap "
                   + "pulls out who owes what — automatically.")
                .font(.cbCallout).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 60)
    }

    /// The rows visible under the current scope — "For you" keeps only the founder's to-dos (theirs,
    /// org-wide, or unassigned); "Everyone" keeps all.
    /// The owner a row groups under — canonicalized so every spelling of one person folds together.
    private func canonicalOwner(_ row: Store.TaskRow) -> String {
        let raw = row.item.owner?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? "" : (canon[raw] ?? raw)
    }

    /// Filter the loaded rows by scope + group them under one canonical "You" section (every variant of the
    /// founder's name folds together), then others alphabetically, "Unassigned" last — and CACHE the result
    /// in `groupedRows`. Called from `load()` (after rows/canon land) and `.onChange(of: scope)`, NEVER from
    /// `body`, so the O(n) filter+group pass doesn't run on every render invalidation. Fast (~1–3 ms for
    /// 332 rows), so running it on the main actor at a scope switch is fine.
    private func regroup() {
        let al = FounderIdentity.aliases   // resolve UserDefaults ONCE, not per row
        var scoped: [Store.TaskRow] = scope == .everyone ? rows : rows.filter {
            // Match on BOTH raw and canonical owner so a folded variant ("Sam" → "Samuel Ortiz") is still mine.
            FounderIdentity.isMine($0.item.owner, aliases: al) || FounderIdentity.isMine(canonicalOwner($0), aliases: al)
        }
        // Name/task search — matches the task text OR the (canonical) owner, so "max" surfaces Alexander's
        // tasks and "pricing" surfaces the pricing to-dos. Case-insensitive substring.
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            scoped = scoped.filter { $0.item.text.lowercased().contains(q) || canonicalOwner($0).lowercased().contains(q) }
        }
        var order: [String] = []
        var map: [String: [Store.TaskRow]] = [:]
        for r in scoped {
            // Group under the CANONICAL owner so "Priya Nadkarni" / "Nadkarnee" / bare "Priya" are one
            // section, not six. A whitespace-only owner folds into "Unassigned" (no blank header).
            let owner = canonicalOwner(r)
            let isMine = FounderIdentity.isAlias(owner, aliases: al)
                || FounderIdentity.isAlias(r.item.owner ?? "", aliases: al)
            let key = isMine ? "You" : (owner.isEmpty ? "Unassigned" : owner)
            if map[key] == nil { order.append(key) }
            map[key, default: []].append(r)
        }
        func rank(_ k: String) -> Int { k == "You" ? 0 : (k == "Unassigned" ? 2 : 1) }
        groupedRows = order.sorted { (rank($0), $0) < (rank($1), $1) }.map { ($0, map[$0]!) }
    }

    /// A section shows its rows when explicitly expanded OR when a search is active (so every matching
    /// section is visible while filtering). "You" is expanded by default (seeded in `expanded`).
    private func isExpanded(_ owner: String) -> Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty || expanded.contains(owner)
    }
    private func toggleExpanded(_ owner: String) {
        withAnimation(Theme.quick) {
            if expanded.contains(owner) { expanded.remove(owner) } else { expanded.insert(owner) }
        }
    }

    /// The count line under the header — reflects scope + filter so a toggle is visibly acknowledged.
    private func scopeSummary(count: Int) -> String {
        let noun = count == 1 ? "task" : "tasks"
        let f = filter == .done ? "completed " : (filter == .open ? "open " : "")
        return scope == .mine ? "\(count) \(f)\(noun) for you" : "\(count) \(f)\(noun) · everyone"
    }

    private func load() {
        let status: ActionItem.Status? = filter == .all ? nil : (filter == .open ? .open : .done)
        let store = env.store
        loadSeq += 1; let seq = loadSeq
        Task {   // SQLite read OFF the main thread (Store is thread-safe) → filter switches never freeze
            let r = await Task.detached { (try? store.tasks(status: status)) ?? [] }.value
            guard loadSeq == seq else { return }   // a newer filter switch superseded this read
            // Build the owner canonical map from the whole loaded set (off-main — clustering is O(owners²)).
            let c = await Task.detached {
                var counts: [String: Int] = [:]
                for row in r {
                    let o = row.item.owner?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if !o.isEmpty { counts[o, default: 0] += 1 }
                }
                return OwnerResolver.canonicalMap(ownerCounts: counts)
            }.value
            guard loadSeq == seq else { return }
            withAnimation(Theme.springy) { rows = r; canon = c; didLoad = true }
            regroup()   // rebuild the cached grouping now that rows/canon are set
        }
    }

    private func tidy() {
        guard !tidying else { return }
        guard !localOnly else {   // belt-and-suspenders: the button is disabled, but never call the cloud here
            withAnimation(Theme.springy) { tidySummary = "Tidy uses cloud AI — turn off Local-only mode in Settings to use it." }
            return
        }
        tidying = true; tidySummary = nil; cancelRequested = false
        tidyTask = Task {
            let outcome = await env.reconcileTasks()
            // If the user hit Cancel, revert anything that was applied (no-op if nothing was) and clear —
            // a TRUE cancel, whether it landed during the AI phase (nothing applied) or the brief apply.
            if cancelRequested {
                cancelRequested = false
                await env.undoTidy()
                tidying = false; tidyTask = nil
                load()
                withAnimation(Theme.springy) { tidySummary = nil }
                return
            }
            tidying = false; tidyTask = nil
            load()
            switch outcome {
            case .cancelled:
                tidyFailed = false
                await env.undoTidy()   // belt-and-suspenders
                withAnimation(Theme.springy) { tidySummary = nil }
            case .failed(let reason):
                tidyFailed = true
                withAnimation(Theme.springy) { tidySummary = reason }
            case .ok(let r):
                tidyFailed = false
                var msg: String
                if r.reworded + r.completed + r.deduped + r.added == 0 {
                    msg = "Your task list is already tidy — nothing to change."
                } else {
                    var parts: [String] = []
                    if r.reworded > 0 { parts.append("reworded \(r.reworded)") }
                    if r.added > 0 { parts.append("added \(r.added)") }
                    if r.completed > 0 { parts.append("marked \(r.completed) done") }
                    if r.deduped > 0 { parts.append("merged \(r.deduped) duplicate\(r.deduped == 1 ? "" : "s")") }
                    msg = "Tidied: " + parts.joined(separator: " · ") + "."
                }
                // No silent truncation: if the corpus exceeded the batch cap, say Tidy reviewed the most
                // recent calls (newer completions are already handled automatically on import).
                if !r.coveredAllCalls { msg += " (reviewed your most recent calls)" }
                withAnimation(Theme.springy) { tidySummary = msg }
            }
        }
    }

    /// Cancel the in-flight Tidy — stops the AI run and undoes anything already applied (true cancel).
    private func cancelTidy() {
        cancelRequested = true
        tidyTask?.cancel()
    }

    /// Undo the last completed Tidy — one tap puts every task back exactly as it was.
    private func undoLastTidy() {
        Task {
            await env.undoTidy()
            load()
            withAnimation(Theme.springy) { tidySummary = "Undone — every task is back the way it was." }
        }
    }

    private func toggle(_ row: Store.TaskRow) {
        let next: ActionItem.Status = row.item.status == .open ? .done : .open
        let store = env.store, id = row.item.id
        Task {   // DB write off-main, then reload + refresh
            await Task.detached { _ = try? store.setTaskStatus(id: id, next) }.value
            load()
            env.refreshReminders()   // keep the daily reminder count fresh
        }
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
                    .font(.title3).foregroundStyle(row.item.status == .done ? Theme.success : Theme.textTertiary)
                    .contentTransition(.symbolEffect(.replace))   // the meaningful circle→check swap; dropped
                    // the extra `.symbolEffect(.bounce)` (redundant animation machinery on every row).
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.item.text)
                    .strikethrough(row.item.status == .done, color: Theme.textSecondary)
                    .foregroundStyle(row.item.status == .done ? Theme.textSecondary : Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: onOpen) {
                    Text("\(row.meetingTitle) · \(row.meetingDate)")
                        .font(.cbCaption).foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(Space.m)
    }
}
