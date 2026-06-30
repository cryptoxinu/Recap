import SwiftUI
import CallBrainCore

struct HomeView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var meetings: [Store.MeetingRow] = []

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        switch h {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        default: return "Good evening"
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("\(greeting) 🌙").font(.largeTitle).bold()

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
                } else {
                    VStack(spacing: 0) {
                        ForEach(meetings.prefix(12)) { m in
                            HStack {
                                Image(systemName: "waveform.circle.fill").foregroundStyle(Theme.accent)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(m.title).bold().lineLimit(1)
                                    Text("\(m.date) · \(m.source)").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .padding(.vertical, 8)
                            if m.id != meetings.prefix(12).last?.id { Divider() }
                        }
                    }
                    .cbCard()
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Home")
        .task { meetings = env.recentMeetings() }
    }

    private func statCard(_ title: String, _ value: String, _ icon: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 38, height: 38)
                .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
            Text(value).font(.title3).bold()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cbCard()
    }
}
