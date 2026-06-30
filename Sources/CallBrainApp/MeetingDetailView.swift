import SwiftUI
import CallBrainCore

struct MeetingDetailView: View {
    @Environment(AppEnvironment.self) private var env
    let meetingID: String
    var highlightChunkID: String? = nil

    @State private var meeting: Store.MeetingRow?
    @State private var groups: [TurnGroup] = []
    @State private var noteLines: [String] = []      // populated for Gemini-notes meetings
    @State private var people: [Entity] = []         // native-NER people mentioned
    @State private var highlightGroupID: Int?

    private var isNotes: Bool { meeting?.source == "gmeet_gemini" }

    struct TurnGroup: Identifiable {
        let id: Int
        let speaker: String
        let tStart: Double?
        let isInferred: Bool
        var lines: [String]
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    Divider()
                    if isNotes {
                        GeminiNotesView(lines: noteLines, title: meeting?.title)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            ForEach(groups) { turn($0).id($0.id) }
                        }
                    }
                }
                .padding(28)
                .frame(maxWidth: 860, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .task {
                await load()
                if let h = highlightGroupID {
                    try? await Task.sleep(for: .milliseconds(120))
                    withAnimation(.easeInOut) { proxy.scrollTo(h, anchor: .center) }
                }
            }
        }
        .navigationTitle(meeting?.title ?? "Meeting")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(meeting?.title ?? "Meeting").font(.largeTitle).bold()
            if let m = meeting {
                HStack(spacing: 14) {
                    Label(m.date, systemImage: "calendar")
                    Label(sourceLabel(m.source), systemImage: "doc.text")
                    if isNotes {
                        Label("AI meeting notes", systemImage: "sparkles")
                    } else {
                        Label("\(groups.count) turns", systemImage: "bubble.left.and.bubble.right")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            if !people.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(people) { Chip(text: $0.name, icon: "person.fill") }
                }
                .padding(.top, 2)
            }
        }
    }

    private func turn(_ g: TurnGroup) -> some View {
        HStack(alignment: .top, spacing: 12) {
            avatar(g.speaker)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(g.speaker).font(.subheadline).bold().foregroundStyle(color(for: g.speaker))
                    if let t = g.tStart, t > 0 {
                        Text(timestamp(t)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    if g.isInferred {
                        Text("inferred").font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(.secondary.opacity(0.15), in: Capsule()).foregroundStyle(.secondary)
                    }
                }
                ForEach(Array(g.lines.enumerated()), id: \.offset) { _, line in
                    Text(line).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        .lineSpacing(2).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(g.id == highlightGroupID ? Theme.accent.opacity(0.12) : .clear))
    }

    private func avatar(_ name: String) -> some View {
        let initials = name.split(separator: " ").prefix(2).compactMap { $0.first.map(String.init) }.joined()
        return Text(initials.isEmpty ? "•" : initials.uppercased())
            .font(.caption.bold()).foregroundStyle(.white)
            .frame(width: 30, height: 30).background(color(for: name), in: Circle())
    }

    private func color(for name: String) -> Color {
        let palette: [Color] = [Theme.accent, .blue, .teal, .green, .orange, .pink, .indigo, .red, .mint]
        var h = 5381
        for b in name.utf8 { h = (h &* 33) &+ Int(b) }
        return palette[(h & 0x7fffffff) % palette.count]
    }

    private func sourceLabel(_ s: String) -> String {
        switch s {
        case "gmeet_gemini": "Google Meet (Gemini notes)"
        case "gmeet_local", "gmeet_cloud": "Google Meet"
        case "fireflies": "Fireflies"
        case "fathom": "Fathom"
        case "cluely": "Cluely"
        case "paste": "Pasted / AI-resolved"
        default: s
        }
    }

    private func timestamp(_ s: Double) -> String {
        let total = Int(s)
        let h = total / 3600, m = (total % 3600) / 60, sec = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    private func load() async {
        if let m = try? env.store.meeting(id: meetingID) { meeting = m }
        let utts = (try? env.store.utterances(meetingID: meetingID)) ?? []
        if meeting?.source == "gmeet_gemini" {
            noteLines = utts.map(\.text)
        } else {
            // People mentioned (native NER) — only for transcripts; notes already list participants.
            people = ((try? env.store.entities(meetingID: meetingID)) ?? [])
                .filter { $0.kind == .person && $0.count >= 2 }.prefix(10).map { $0 }
        }
        let rows: [(speaker: String, t: Double?, inferred: Bool, text: String)]
        if utts.isEmpty {
            rows = ((try? env.store.transcript(meetingID: meetingID)) ?? [])
                .map { (speaker: $0.speaker ?? "—", t: $0.tStart, inferred: false, text: $0.text) }
        } else {
            rows = utts.map { (speaker: $0.speaker ?? "—", t: $0.tStart, inferred: $0.isInferred, text: $0.text) }
        }
        var result: [TurnGroup] = []
        for r in rows {
            if let last = result.last, last.speaker == r.speaker {
                result[result.count - 1].lines.append(r.text)
            } else {
                result.append(TurnGroup(id: result.count, speaker: r.speaker, tStart: r.t,
                                        isInferred: r.inferred, lines: [r.text]))
            }
        }
        groups = result

        // Best-effort: find the group matching the cited chunk to scroll/highlight.
        if let cid = highlightChunkID, let hit = (try? env.store.chunks(ids: [cid]))?.first {
            let needle = String(hit.text.prefix(40)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !needle.isEmpty {
                highlightGroupID = result.first(where: { g in g.lines.contains(where: { $0.contains(needle) || needle.contains($0.prefix(30)) }) })?.id
            }
        }
    }
}
