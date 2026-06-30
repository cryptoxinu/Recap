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
        Group {
            if meetings.isEmpty {
                ContentUnavailableView("No meetings yet", systemImage: "calendar",
                                       description: Text("Import a transcript to get started."))
            } else {
                Table(filtered) {
                    TableColumn("Title", value: \.title)
                    TableColumn("Date", value: \.date)
                    TableColumn("Source", value: \.source)
                }
            }
        }
        .navigationTitle("Meetings")
        .searchable(text: $query, prompt: "Search calls")
        .task { meetings = env.recentMeetings() }
    }
}
