import SwiftUI
import CallBrainCore

struct HomeView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var meetings: [Store.MeetingRow] = []
    @State private var chat = ChatModel()
    @State private var openMeetingID: String?

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
        let m = await Task.detached { (try? store.recentMeetings()) ?? [] }.value
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
                    statCard("Calls indexed", "\(meetings.count)", "calendar", Theme.accent)
                    statCard("Ask AI", "Ready", "sparkles", .pink)
                    statCard("Engine", "Local + cloud", "bolt.horizontal", .orange)
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
