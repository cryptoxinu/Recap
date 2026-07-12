import SwiftUI
import CallBrainCore

struct HomeView: View {
    @Environment(AppEnvironment.self) private var env
    var onNavigate: ((SidebarItem) -> Void)? = nil   // lets a card jump to another sidebar tab
    @State private var meetings: [Store.MeetingRow] = []
    @State private var didLoad = false                // true after the first meetings read completes
    // SHARE the Ask-tab chat model (not a private instance) so a chat started here is the SAME conversation
    // the Ask tab shows, and it lands in the Ask-tab Recents live (audit: Home chats weren't surfacing).
    private var chat: ChatModel { env.askChat }
    @State private var loadSeq = 0                    // drops out-of-order off-main meeting reloads
    @State private var status = SystemStatus()        // live engine/provider health for the Home cards
    @State private var showProviderPicker = false
    @State private var showEngineStatus = false
    @State private var digest: String?                // Daily Digest (Task 7.4), cached per day
    @State private var openTasks: [Store.TaskRow] = []
    @State private var reviewCounts: (dups: Int, imports: Int) = (0, 0)
    @State private var profileSuggestions: [ProfileEnricher.Suggestion] = []   // Task 8.6
    @State private var calendar = CalendarBriefs()                              // Task 9.2

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: "Good morning"
        case 12..<17: "Good afternoon"
        default: "Good evening"
        }
    }

    /// A quiet subtitle under the greeting — today's date + corpus size. Informative, not decorative
    /// (replaces the AI-slop time-of-day emoji).
    private var greetingSubtitle: String {
        let day = Date().formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        guard didLoad else { return day }
        let n = meetings.count
        return "\(day) · \(n) call\(n == 1 ? "" : "s") indexed"
    }

    /// The premium CLI Recap will actually run — for reflecting its health on the Engine card face.
    private var premiumOK: Bool { env.providerPrimary == .codex ? status.snap.codexOK : status.snap.claudeOK }

    /// The Engine card's face value — honest about a degraded engine once the probe has run.
    private var engineValue: String {
        guard status.snap.loaded else { return "Local + cloud" }   // still probing — neutral, not alarming
        if !status.snap.ollamaOK && !premiumOK { return "Offline" }
        if !status.snap.ollamaOK { return "Ollama off" }
        if !premiumOK { return "Local only" }
        return "Local + cloud"
    }
    private var engineTint: Color {
        guard status.snap.loaded else { return Theme.textTertiary }        // still probing — neutral
        if !status.snap.ollamaOK && !premiumOK { return Theme.danger }     // offline
        if !status.snap.ollamaOK || !premiumOK { return Theme.warning }    // degraded
        return Theme.accent                                                // healthy — calm brand tint
    }

    var body: some View {
        HStack(spacing: 0) {
            mainColumn
            Divider()
            askColumn
        }
        .navigationTitle("Home")
        .task {
            await loadMeetings()
            await loadBriefing()
            await calendar.refresh(store: env.store)   // no-op unless already authorized (9.2)
            // Titles + categories are cheap; full summaries are generated LAZILY when a call is opened
            // (no eager 14B storm on launch — that was the fan/lag cause).
            env.backfillTitleIntelligence(); env.backfillCategories()
            // Probe engine health so the "Engine" card face reflects reality (Ollama off / no CLI) instead
            // of always claiming "Local + cloud" (off the render/launch hot path — the probe is async).
            await status.refresh()
        }
        .onChange(of: env.titlesRevision) {   // live-refresh as AI titles/categories land — animated, not popped
            Task { await loadMeetings() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .cbDigestUpdated)) { note in
            if let t = note.object as? String { digest = t }      // qwen polish lands live (gate MED)
        }
    }

    /// Load the recent-calls list OFF the main thread (Store is thread-safe), then animate it in — so Home
    /// never blocks the UI on the SQLite read (launch or when a title/category lands).
    private func loadMeetings() async {
        let store = env.store
        loadSeq += 1; let seq = loadSeq
        let m = await Task.detached { (try? store.recentMeetings()) ?? [] }.value
        guard loadSeq == seq else { return }   // a newer reload (title/category landed) superseded this one
        withAnimation(Theme.springy) { meetings = m; didLoad = true }
    }

    /// Open tasks (You first), review counts, and the Daily Digest (Task 7.4).
    private func loadBriefing() async {
        let store = env.store
        let (tasks, dups, imports) = await Task.detached { () -> ([Store.TaskRow], Int, Int) in
            let all = (try? store.tasks(status: .open, limit: 100)) ?? []
            let aliases = FounderIdentity.aliases
            let mine = all.filter { FounderIdentity.isAlias($0.item.owner, aliases: aliases) }
            let rest = all.filter { !FounderIdentity.isAlias($0.item.owner, aliases: aliases) }
            let dups = DuplicateScan.count(store)
            let imports = ((try? store.importJobs(limit: 100)) ?? []).filter { $0.state == .needsReview }.count
            return (Array((mine + rest).prefix(5)), dups, imports)
        }.value
        openTasks = tasks; reviewCounts = (dups, imports)   // no insert animation — it nudges scroll offset
        // Profile enrichment (Task 8.6 — gate HIGH: the original wiring was lost to a silent
        // patch no-op; this load is what makes the review card exist).
        let profile = PersonalProfile.load()
        let sugg = await Task.detached { (try? ProfileEnricher.suggestions(store: store, profile: profile)) ?? [] }.value
        profileSuggestions = sugg

        // Digest: cache-first; regenerate when the day flips or the corpus changes (fingerprint
        // covers deletes/edits at the same count + open-task swings — gate MED).
        let today = TimeCode.ymd(Date())
        let openCount = env.openTaskCountCached
        let fp = "\(meetings.count)|\(meetings.first?.id ?? "")|\(meetings.first?.aiSummary?.count ?? 0)|\(openCount)"
        if let hit = DailyDigest.cached(today: today, fingerprint: fp) { digest = hit; return }
        let recentMeta = meetings.filter { m in
            guard let d = Self.daysAgo(m.date) else { return false }
            return d <= 1
        }.map { m in
            // Fact-based TL;DR beats the naming one-liner (founder: the digest was slop) —
            // fall back to aiSummary only when a call has no v2 summary yet.
            (title: m.displayTitle,
             oneLiner: DailyDigest.tldrLine(fromSummary: m.callSummary) ?? m.aiSummary)
        }
        let facts = DailyDigest.assemble(recentMeta, openTasks: openCount)
        digest = facts                                            // deterministic text NOW
        DailyDigest.save(facts, today: today, fingerprint: fp)    // cache floor
        let jobs = env.jobs
        Task.detached(priority: .utility) {                       // local-model polish upgrades cache + UI
            await jobs.run(label: "daily-digest", priority: .background) {
                guard let polished = await DailyDigest.polish(facts, recent: recentMeta,
                                                              forRole: PersonalProfile.load().role) else { return }
                DailyDigest.save(polished, today: today, fingerprint: fp)
                await MainActor.run { NotificationCenter.default.post(name: .cbDigestUpdated, object: polished) }
            }
        }
    }

    /// One-tap accept (Task 8.6) — merges into the persisted profile, idempotently.
    private func acceptSuggestion(_ s: ProfileEnricher.Suggestion) {
        let merged = ProfileEnricher.accept(s, into: PersonalProfile.load())
        merged.save()
        withAnimation(Theme.springy) { profileSuggestions.removeAll { $0.id == s.id } }
    }

    static func daysAgo(_ ymd: String) -> Int? {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"; df.locale = Locale(identifier: "en_US_POSIX")
        guard let d = df.date(from: ymd) else { return nil }
        return Calendar.current.dateComponents([.day], from: d, to: Date()).day
    }

    private var mainColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(greeting).font(.cbLargeTitle).foregroundStyle(Theme.textPrimary)
                    Text(greetingSubtitle).font(.cbCallout).foregroundStyle(Theme.textSecondary)
                }

                if let err = env.initError {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(.cbCallout).foregroundStyle(Theme.warning)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Space.m)
                        .background(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).fill(Theme.warningSoft))
                        .transition(.opacity)
                }

                HStack(spacing: Space.m) {
                    // Calls → jump to the Meetings list.
                    Button { onNavigate?(.meetings) } label: {
                        // Hold a placeholder until the first load returns so it never reads a false "0".
                        CBStatTile(title: "Calls indexed", value: didLoad ? "\(meetings.count)" : "—", systemImage: CBIcon.call)
                    }.buttonStyle(.plain)

                    // Ask AI → quick-pick the premium provider (Claude ⇄ Codex CLI).
                    Button { showProviderPicker = true } label: {
                        CBStatTile(title: "Premium AI", value: env.providerPrimary == .codex ? "Codex" : "Claude",
                                   systemImage: CBIcon.premium)
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showProviderPicker, arrowEdge: .bottom) { providerPicker }

                    // Engine → live model + Ollama + provider health. The card FACE reflects probed health
                    // (not a hardcoded healthy "Local + cloud") so a degraded engine is visible at a glance.
                    Button { showEngineStatus = true } label: {
                        CBStatTile(title: "Engine", value: engineValue, systemImage: "bolt.horizontal", tint: engineTint)
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showEngineStatus, arrowEdge: .bottom) { engineStatus }
                }

                // ── Calendar prep (Task 9.2, TCC-gated) ─────────────────────
                if calendar.state == .authorized, !calendar.briefs.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Today's meetings", systemImage: "calendar.badge.clock")
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(calendar.briefs) { b in
                            HStack(spacing: 8) {
                                Text(b.start, style: .time).font(.callout.weight(.medium)).monospacedDigit()
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(b.title).font(.callout).lineLimit(1)
                                    if let who = b.attendee {
                                        Text("\(who)\(b.openTaskCount > 0 ? " · \(b.openTaskCount) open item\(b.openTaskCount == 1 ? "" : "s") with them" : "")")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if let mid = b.lastMeetingID {
                                    Button("Last call") { env.openMeeting(mid) }
                                        .buttonStyle(.bordered).controlSize(.small)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cbCard()
                    .transition(.opacity)
                } else if calendar.state == .unknown, calendar.chipVisible {
                    HStack(spacing: 10) {
                        Image(systemName: "calendar.badge.clock").foregroundStyle(Theme.accent)
                        Text("Prep me for today's meetings").font(.callout)
                        Text("· uses your calendar, stays on this Mac").font(.caption).foregroundStyle(.tertiary)
                        Spacer()
                        Button("Connect calendar") { Task { await calendar.connect(store: env.store) } }
                            .buttonStyle(.bordered).controlSize(.small)
                        Button { calendar.declineChip() } label: { Image(systemName: "xmark").font(.caption2) }
                            .buttonStyle(.plain).foregroundStyle(.tertiary)
                    }
                    .cbCard()
                    .transition(.opacity)
                }

                // ── Morning briefing (Task 7.4) ─────────────────────────────
                if let digest {
                    VStack(alignment: .leading, spacing: Space.s) {
                        CBSectionHeader(title: "Daily digest", systemImage: "sun.horizon")
                        // Render as markdown — the local model returns **bold**/bullets, which leaked as
                        // literal asterisks in a plain Text (recon: "AI output looks raw").
                        MarkdownAnswerView(text: digest)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cbCard()
                    .transition(.opacity)
                }

                if !openTasks.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label("Your open tasks", systemImage: "checklist")
                                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Spacer()
                            Button("All tasks") { onNavigate?(.tasks) }
                                .buttonStyle(.plain).font(.caption).foregroundStyle(Theme.accent)
                        }
                        ForEach(openTasks) { row in
                            // Opens the task's call — so the leading glyph must NOT look like a checkbox
                            // (recon: fake-checkbox that doesn't complete). A small accent dot + trailing
                            // chevron reads as "open", and completion lives on the Tasks surface.
                            Button { env.openMeeting(row.item.meetingID) } label: {
                                HStack(spacing: Space.s) {
                                    Circle().fill(Theme.accent).frame(width: 5, height: 5)
                                    Text(row.item.text).font(.cbCallout).foregroundStyle(Theme.textPrimary).lineLimit(1)
                                    Spacer()
                                    if let owner = row.item.owner, !owner.isEmpty {
                                        Text(owner).font(.cbCaption).foregroundStyle(Theme.textTertiary)
                                    }
                                    Image(systemName: "chevron.right").font(.cbCaption).foregroundStyle(Theme.textTertiary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cbCard()
                    .transition(.opacity)
                }

                if reviewCounts.dups > 0 || reviewCounts.imports > 0 {
                    HStack(spacing: 12) {
                        Label("Needs review", systemImage: "exclamationmark.bubble")
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        if reviewCounts.dups > 0 {
                            Button("\(reviewCounts.dups) possible duplicate\(reviewCounts.dups == 1 ? "" : "s")") {
                                onNavigate?(.meetings)
                            }.buttonStyle(.link).font(.callout)
                        }
                        if reviewCounts.imports > 0 {
                            Button("\(reviewCounts.imports) import\(reviewCounts.imports == 1 ? "" : "s") to confirm") {
                                onNavigate?(.imports)
                            }.buttonStyle(.link).font(.callout)
                        }
                        Spacer()
                    }
                    .cbCard()
                    .transition(.opacity)
                }

                if !profileSuggestions.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Label("Suggested focus areas", systemImage: "scope")
                                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Text("· topics from your calls — adding one makes Ask treat it as your project")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                        ForEach(profileSuggestions) { s in
                            HStack(spacing: 8) {
                                Text("Add “\(s.text)” to your focus areas?")
                                    .font(.callout).lineLimit(1)
                                Text("· \(s.detail)").font(.caption).foregroundStyle(.tertiary)
                                Spacer()
                                Button("Add") { acceptSuggestion(s) }
                                    .buttonStyle(.bordered).controlSize(.small)
                                Button { profileSuggestions.removeAll { $0.id == s.id } } label: {
                                    Image(systemName: "xmark").font(.caption2)
                                }.buttonStyle(.plain).foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cbCard()
                    .transition(.opacity)
                }

                Text("Recent calls").font(.cbHeadline).foregroundStyle(Theme.textPrimary)
                if meetings.isEmpty && didLoad {
                    // Genuinely empty (the first load finished with nothing) — show the onboarding card.
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No calls yet.").bold()
                        Text("Go to **Import**, paste a transcript, and it'll show up here — then ask it anything.")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cbCard()
                    .transition(.opacity)
                } else if meetings.isEmpty {
                    // Still loading — a neutral placeholder so the onboarding "No calls yet" card doesn't
                    // FLASH for a returning user before the SQLite read completes (looks like data vanished).
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading your calls…").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cbCard()
                    .transition(.opacity)
                } else {
                    VStack(spacing: 0) {
                        ForEach(meetings.prefix(12)) { m in
                            Button { env.openMeeting(m.id) } label: { recentRow(m).cbHoverRow() }
                                .buttonStyle(.plain)
                            if m.id != meetings.prefix(12).last?.id { Divider() }
                        }
                    }
                    .cbCard(padding: 6)
                    .transition(.opacity)
                }
            }
            .padding(Space.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Late-inserting briefing cards (calendar chip / suggestions land async) must not nudge
        // the scroll offset — the greeting was sliding under the toolbar (gate follow-up).
        .defaultScrollAnchor(.top)
    }

    private var askColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Ask your calls")
                .font(.cbHeadline).foregroundStyle(Theme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Space.l).padding(.top, Space.l).padding(.bottom, Space.xs)
            AskPanel(model: chat, compact: true)
        }
        .frame(width: 372)
        .background(Theme.surfaceSunken)
    }

    /// One recent-call row: the proper (AI) name, a one-line intelligence summary under it, then date·source.
    private func recentRow(_ m: Store.MeetingRow) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform.circle.fill").foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(m.displayTitle).bold().lineLimit(1)
                if let s = m.aiSummary, !s.isEmpty {
                    Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Text("\(Self.friendlyDate(m.date)) · \(sourceLabel(m.source))").font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private func sourceLabel(_ s: String) -> String {
        switch s {
        case "gmeet_gemini": "Google Meet (Gemini notes)"
        case "gmeet_captions": "Google Meet captions"
        case "gmeet_local", "gmeet_cloud": "Google Meet"
        case "fireflies": "Fireflies"; case "fathom": "Fathom"; case "cluely": "Cluely"
        case "paste": "Pasted"; default: s
        }
    }

    // Parse the canonical YYYY-MM-DD → a readable "Today"/"Yesterday"/"Jun 30, 2026" label, so the
    // recent-calls list reads like a product, not database rows. Parses via integer components (no shared
    // mutable DateFormatter — Sendable-safe under Swift 6). Falls back to the raw string on any mismatch.
    static func friendlyDate(_ ymd: String) -> String {
        let parts = ymd.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return ymd }
        let cal = Calendar.current
        var comps = DateComponents(); comps.year = parts[0]; comps.month = parts[1]; comps.day = parts[2]
        guard let date = cal.date(from: comps) else { return ymd }
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.month(.abbreviated).day().year())
    }

    // MARK: - Home-card popovers (provider picker + engine status)

    /// Quick-pick the premium generation provider — one tap flips Claude ⇄ Codex CLI (persisted), with a
    /// live availability dot so a missing CLI is obvious.
    private var providerPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Premium AI provider").font(.headline).padding(.bottom, 2)
            providerRow(.claude, "Claude CLI", "claude -p", status.snap.claudeOK)
            providerRow(.codex, "Codex CLI", "codex exec", status.snap.codexOK)
            Text("Premium answers + one-tap “Regenerate” use your CLI subscription. Everyday work stays on the local model — free.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6).frame(width: 300, alignment: .leading)
        }
        .padding(16)
        .task { await status.refresh() }
    }

    private func providerRow(_ id: ProviderID, _ name: String, _ cmd: String, _ available: Bool) -> some View {
        Button {
            env.setProviderPrimary(id)
            showProviderPicker = false
        } label: {
            HStack(spacing: 10) {
                Image(systemName: env.providerPrimary == id ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(env.providerPrimary == id ? Theme.accent : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).foregroundStyle(.primary)
                    Text(cmd).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Spacer()
                healthDot(status.snap.loaded ? available : nil)
            }
            .padding(.vertical, 6).padding(.horizontal, 8).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Live engine status — what Recap is actually running: the local models (summary + embeddings)
    /// via Ollama, and the premium CLI provider — each with a green/red health dot.
    private var engineStatus: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Engine status").font(.headline)
            let probing = !status.snap.loaded   // while the async probe runs, DON'T show definitive failures
            statusLine("Ollama (local models)", probing ? nil : status.snap.ollamaOK,
                       probing ? "Checking…" : (status.snap.ollamaOK ? "running" : "not running — start Ollama to summarize on-device"))
            statusLine("Summaries · \(env.localSummaryModel)", probing ? nil : status.hasModel(env.localSummaryModel),
                       probing ? "Checking…" : (status.hasModel(env.localSummaryModel) ? "ready" : "run: ollama pull \(env.localSummaryModel)"))
            statusLine("Embeddings · nomic-embed-text", probing ? nil : status.hasModel("nomic-embed-text"),
                       probing ? "Checking…" : (status.hasModel("nomic-embed-text") ? "ready" : "run: ollama pull nomic-embed-text"))
            Divider()
            statusLine("Premium · \(env.providerPrimary == .codex ? "Codex" : "Claude") CLI",
                       probing ? nil : premiumOK, probing ? "Checking…" : (premiumOK ? "available" : "CLI not found"))
            HStack {
                Spacer()
                Button { Task { await status.refresh() } } label: {
                    Label(status.checking ? "Checking…" : "Refresh", systemImage: "arrow.clockwise")
                        .font(.caption)
                }.buttonStyle(.plain).foregroundStyle(Theme.accent).disabled(status.checking)
            }
        }
        .padding(16).frame(width: 340, alignment: .leading)
        .task { await status.refresh() }
    }

    private func statusLine(_ title: String, _ ok: Bool?, _ detail: String) -> some View {
        HStack(spacing: 10) {
            healthDot(ok)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).foregroundStyle(.primary)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    /// nil = unknown (still probing) → grey; true → success; false → danger.
    private func healthDot(_ ok: Bool?) -> some View {
        Circle().fill(ok == nil ? Theme.textTertiary : (ok! ? Theme.success : Theme.danger))
            .frame(width: 9, height: 9)
    }

}
