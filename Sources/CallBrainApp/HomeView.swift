import SwiftUI
import CallBrainCore

struct HomeView: View {
    @Environment(AppEnvironment.self) private var env
    var onNavigate: ((SidebarItem) -> Void)? = nil   // lets a card jump to another sidebar tab
    @State private var meetings: [Store.MeetingRow] = []
    @State private var chat = ChatModel()
    @State private var openMeetingID: String?
    @State private var loadSeq = 0                    // drops out-of-order off-main meeting reloads
    @State private var status = SystemStatus()        // live engine/provider health for the Home cards
    @State private var showProviderPicker = false
    @State private var showEngineStatus = false

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: "Good morning"
        case 12..<17: "Good afternoon"
        default: "Good evening"
        }
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
            // Titles + categories are cheap; full summaries are generated LAZILY when a call is opened
            // (no eager 14B storm on launch — that was the fan/lag cause).
            env.backfillTitleIntelligence(); env.backfillCategories()
        }
        .onChange(of: env.titlesRevision) {   // live-refresh as AI titles/categories land — animated, not popped
            Task { await loadMeetings() }
        }
        .sheet(item: $openMeetingID) { id in
            NavigationStack {
                MeetingWorkspaceView(meetingID: id)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { openMeetingID = nil } } }
            }
            .frame(minWidth: 1000, minHeight: 680)
        }
    }

    /// Load the recent-calls list OFF the main thread (Store is thread-safe), then animate it in — so Home
    /// never blocks the UI on the SQLite read (launch or when a title/category lands).
    private func loadMeetings() async {
        let store = env.store
        loadSeq += 1; let seq = loadSeq
        let m = await Task.detached { (try? store.recentMeetings()) ?? [] }.value
        guard loadSeq == seq else { return }   // a newer reload (title/category landed) superseded this one
        withAnimation(Theme.springy) { meetings = m }
    }

    private var mainColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("\(greeting) 🌙").font(.largeTitle).bold()

                if let err = env.initError {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 10).fill(.orange.opacity(0.12)))
                        .transition(.opacity)
                }

                HStack(spacing: 14) {
                    // Calls → jump to the Meetings list.
                    Button { onNavigate?(.meetings) } label: {
                        statCard("Calls indexed", "\(meetings.count)", "calendar", Theme.accent)
                    }.buttonStyle(.plain)

                    // Ask AI → quick-pick the premium provider (Claude ⇄ Codex CLI).
                    Button { showProviderPicker = true } label: {
                        statCard("Premium AI", env.providerPrimary == .codex ? "Codex" : "Claude", "sparkles", .pink)
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showProviderPicker, arrowEdge: .bottom) { providerPicker }

                    // Engine → live model + Ollama + provider health.
                    Button { showEngineStatus = true } label: {
                        statCard("Engine", "Local + cloud", "bolt.horizontal", .orange)
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showEngineStatus, arrowEdge: .bottom) { engineStatus }
                }

                Text("Recent calls").font(.headline)
                if meetings.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No calls yet.").bold()
                        Text("Go to **Import**, paste a transcript, and it'll show up here — then ask it anything.")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cbCard()
                    .transition(.opacity)
                } else {
                    VStack(spacing: 0) {
                        ForEach(meetings.prefix(12)) { m in
                            Button { openMeetingID = m.id } label: { recentRow(m).cbHoverRow() }
                                .buttonStyle(.plain)
                            if m.id != meetings.prefix(12).last?.id { Divider() }
                        }
                    }
                    .cbCard(padding: 6)
                    .transition(.opacity)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var askColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Ask your calls")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 4)
            AskPanel(model: chat, compact: true)
        }
        .frame(width: 372)
        .background(Theme.cardFill.opacity(0.35))
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
                Text("\(m.date) · \(sourceLabel(m.source))").font(.caption2).foregroundStyle(.tertiary)
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
        case "gmeet_local", "gmeet_cloud": "Google Meet"
        case "fireflies": "Fireflies"; case "fathom": "Fathom"; case "cluely": "Cluely"
        case "paste": "Pasted"; default: s
        }
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

    /// Live engine status — what CallBrain is actually running: the local models (summary + embeddings)
    /// via Ollama, and the premium CLI provider — each with a green/red health dot.
    private var engineStatus: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Engine status").font(.headline)
            statusLine("Ollama (local models)", status.snap.loaded ? status.snap.ollamaOK : nil,
                       status.snap.ollamaOK ? "running" : "not running — start Ollama to summarize on-device")
            statusLine("Summaries · \(env.localSummaryModel)", status.snap.loaded ? status.hasModel(env.localSummaryModel) : nil,
                       status.hasModel(env.localSummaryModel) ? "ready" : "run: ollama pull \(env.localSummaryModel)")
            statusLine("Embeddings · nomic-embed-text", status.snap.loaded ? status.hasModel("nomic-embed-text") : nil,
                       status.hasModel("nomic-embed-text") ? "ready" : "run: ollama pull nomic-embed-text")
            Divider()
            let premiumOK = env.providerPrimary == .codex ? status.snap.codexOK : status.snap.claudeOK
            statusLine("Premium · \(env.providerPrimary == .codex ? "Codex" : "Claude") CLI",
                       status.snap.loaded ? premiumOK : nil, premiumOK ? "available" : "CLI not found")
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

    /// nil = unknown (still probing) → grey; true → green; false → red.
    private func healthDot(_ ok: Bool?) -> some View {
        Circle().fill(ok == nil ? Color.secondary.opacity(0.4) : (ok! ? .green : .red))
            .frame(width: 9, height: 9)
    }

    private func statCard(_ title: String, _ value: String, _ icon: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon)
                .font(.title3).foregroundStyle(tint)
                .frame(width: 38, height: 38)
                .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
            Text(value).font(.title3).bold().contentTransition(.numericText())
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cbCard()
    }
}
