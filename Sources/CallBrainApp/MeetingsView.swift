import SwiftUI
import CallBrainCore

struct MeetingsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var meetings: [Store.MeetingRow] = []
    @State private var query = ""
    @State private var dupCount = 0
    @State private var showDupReview = false
    // Navigation path (seedable for screenshot QA: CALLBRAIN_OPEN_MEETING=<id> opens straight to the workspace).
    @State private var path: [String] = {
        let id = ProcessInfo.processInfo.environment["CALLBRAIN_OPEN_MEETING"] ?? ""
        return id.isEmpty ? [] : [id]
    }()

    private var filtered: [Store.MeetingRow] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return meetings }
        return meetings.filter { $0.title.lowercased().contains(q) || $0.source.lowercased().contains(q) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if meetings.isEmpty {
                    ContentUnavailableView("No meetings yet", systemImage: "calendar",
                                           description: Text("Import a transcript to get started."))
                } else {
                    VStack(spacing: 0) {
                        if dupCount > 0 { dupBanner }
                        List(filtered) { m in
                            NavigationLink(value: m.id) { row(m) }
                        }
                        .navigationDestination(for: String.self) { id in
                            MeetingWorkspaceView(meetingID: id)
                        }
                    }
                }
            }
            .navigationTitle("Meetings")
            .searchable(text: $query, prompt: "Search calls")
        }
        .task {
            reload()
            if ProcessInfo.processInfo.environment["CALLBRAIN_DUPREVIEW"] == "1" { showDupReview = true }
        }
        .sheet(isPresented: $showDupReview, onDismiss: reload) { DuplicateReviewView() }
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
        meetings = env.recentMeetings()
        dupCount = DuplicateScan.count(env.store)
    }

    private func row(_ m: Store.MeetingRow) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform.circle.fill").foregroundStyle(Theme.accent).font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(m.title).bold().lineLimit(1)
                Text("\(m.date) · \(m.source)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}
