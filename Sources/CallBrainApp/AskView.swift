import SwiftUI
import CallBrainCore

struct AskMessage: Identifiable, Equatable {
    enum Role { case user, assistant }
    let id = UUID()
    let role: Role
    var text: String
    var citations: [String]
    var pending: Bool = false
    var status: String? = nil
}

struct AskView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var query = ""
    @State private var messages: [AskMessage] = []
    @State private var busy = false

    static let suggestions = [
        "What are my action items this week?",
        "What did Max explain about TEEs?",
        "What is the status of BitRouter?",
        "What pricing did we decide for amp code?",
    ]

    var body: some View {
        VStack(spacing: 0) {
            if messages.isEmpty { emptyState } else { transcript }
            inputBar
        }
        .navigationTitle("Ask AI")
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "sparkles").font(.system(size: 38)).foregroundStyle(Theme.accent)
            Text("Ask anything across your calls").font(.title2).bold()
            Text("Grounded answers with citations — it refuses rather than guess.")
                .foregroundStyle(.secondary)
            VStack(spacing: 8) {
                ForEach(Self.suggestions, id: \.self) { s in
                    Button { ask(s) } label: {
                        Label(s, systemImage: "arrow.up.forward")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .frame(maxWidth: 460)
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(messages) { m in AskMessageView(message: m) }
            }
            .padding(20)
        }
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Ask anything across your meetings…", text: $query, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .onSubmit { ask(query) }
            Button { ask(query) } label: {
                Image(systemName: "arrow.up.circle.fill").font(.title)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
            .disabled(busy || query.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.cardFill))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hairline))
        .padding(16)
    }

    private func ask(_ text: String) {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !busy else { return }
        query = ""
        Task { await run(q) }
    }

    @MainActor
    private func run(_ q: String) async {
        busy = true
        messages.append(AskMessage(role: .user, text: q, citations: []))
        var pending = AskMessage(role: .assistant, text: "Thinking…", citations: [], pending: true)
        messages.append(pending)
        let pid = pending.id
        defer { busy = false }
        do {
            let ans = try await env.ask.ask(q)
            let cites = ans.citations.map { "[\($0.tag)] \($0.speaker ?? "Unknown") — \($0.text.prefix(90))…" }
            if let i = messages.firstIndex(where: { $0.id == pid }) {
                messages[i].text = ans.text
                messages[i].citations = cites
                messages[i].pending = false
                messages[i].status = ans.status == .answered ? "\(ans.citations.count) sources" : "no sources"
            }
        } catch {
            if let i = messages.firstIndex(where: { $0.id == pid }) {
                messages[i].text = "Couldn't answer: \(error)"
                messages[i].pending = false
            }
        }
        _ = pending
    }
}

struct AskMessageView: View {
    let message: AskMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: message.role == .user ? "person.crop.circle.fill" : "sparkles")
                    .foregroundStyle(message.role == .user ? Color.secondary : Theme.accent)
                Text(message.role == .user ? "You" : "CallBrain").font(.subheadline).bold()
                if let s = message.status {
                    Text(s).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            if message.pending {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Thinking…").foregroundStyle(.secondary) }
            } else if message.role == .assistant {
                MarkdownAnswerView(text: message.text).textSelection(.enabled)
            } else {
                Text(message.text).textSelection(.enabled)
            }
            if !message.citations.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(message.citations, id: \.self) { c in
                        Text(c).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cbCard()
    }
}
