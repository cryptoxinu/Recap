import SwiftUI
import CallBrainCore

struct MeetingsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var meetings: [Store.MeetingRow] = []
    @State private var query = ""

    private var filtered: [Store.MeetingRow] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return meetings }
        return meetings.filter { $0.title.lowercased().contains(q) || $0.source.lowercased().contains(q) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if meetings.isEmpty {
                    ContentUnavailableView("No meetings yet", systemImage: "calendar",
                                           description: Text("Import a transcript to get started."))
                } else {
                    List(filtered) { m in
                        NavigationLink(value: m.id) { row(m) }
                    }
                    .navigationDestination(for: String.self) { id in
                        MeetingDetailView(meetingID: id)
                    }
                }
            }
            .navigationTitle("Meetings")
            .searchable(text: $query, prompt: "Search calls")
        }
        .task { meetings = env.recentMeetings() }
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
