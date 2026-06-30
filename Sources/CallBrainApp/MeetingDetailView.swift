import SwiftUI
import CallBrainCore

struct MeetingDetailView: View {
    @Environment(AppEnvironment.self) private var env
    let meetingID: String
    @State private var meeting: Store.MeetingRow?
    @State private var rows: [Store.TranscriptRow] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(meeting?.title ?? "Meeting").font(.title).bold()
                if let m = meeting {
                    HStack(spacing: 8) {
                        Label(m.date, systemImage: "calendar")
                        Label(m.source, systemImage: "doc.text")
                        Label("\(rows.count) segments", systemImage: "text.alignleft")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Divider()
                Text("Transcript").font(.headline)

                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { r in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 8) {
                                Text(r.speaker ?? "—").font(.subheadline).bold().foregroundStyle(Theme.accent)
                                if let t = r.tStart, t > 0 {
                                    Text(Self.timestamp(t)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                }
                            }
                            Text(r.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                        Divider()
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(meeting?.title ?? "Meeting")
        .task {
            if let m = try? env.store.meeting(id: meetingID) { meeting = m }
            rows = (try? env.store.transcript(meetingID: meetingID)) ?? []
        }
    }

    static func timestamp(_ s: Double) -> String {
        let total = Int(s)
        let h = total / 3600, m = (total % 3600) / 60, sec = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}
