import SwiftUI
import CallBrainCore

struct Cite: Identifiable, Equatable, Hashable {
    let tag: String
    let meetingID: String
    let chunkID: String
    let summary: String
    var id: String { chunkID }
}

struct AskMessage: Identifiable, Equatable {
    enum Role { case user, assistant }
    let id = UUID()
    let role: Role
    var text: String
    var citations: [Cite]
    var pending: Bool = false
    var status: String? = nil
    var steps: [AskEngine.ReasoningStep] = []   // live agentic reasoning timeline (Phase 4.5)
}

private struct MeetingRef: Identifiable, Equatable { let id: String; let chunkID: String }

/// The Ask-AI chat — reused full-screen (Ask AI tab) and as the persistent panel on Home. Conversation
/// state + persistence live in a shared `ChatModel` (Phase 4.5), so the same thread can be shown next to
/// a Recents rail and survive across launches.
struct AskPanel: View {
    @Environment(AppEnvironment.self) private var env
    @Bindable var model: ChatModel
    var compact: Bool = false
    /// When set (the meeting workspace), a citation tap calls this (scroll the transcript pane) instead
    /// of opening a sheet.
    var onCite: ((Cite) -> Void)? = nil

    @State private var query = ""
    @State private var sheet: MeetingRef?

    static let globalSuggestions = [
        "What are my action items this week?",
        "What did Max explain about TEEs?",
        "What is the status of BitRouter?",
        "What pricing did we decide for amp code?",
    ]
    static let meetingSuggestions = [
        "Summarize this call",
        "What are the action items?",
        "What decisions were made?",
        "What should I follow up on?",
    ]
    private var suggestions: [String] { model.meetingID == nil ? Self.globalSuggestions : Self.meetingSuggestions }

    private var messages: [AskMessage] { model.messages }
    private var busy: Bool { model.busy }

    var body: some View {
        VStack(spacing: 0) {
            if messages.isEmpty { emptyState } else { transcript }
            if model.saveFailed {
                Label("Couldn't save this chat — check disk space or relaunch.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, compact ? 14 : 18).padding(.top, 4)
            }
            inputBar
        }
        .sheet(item: $sheet) { ref in
            NavigationStack {
                MeetingDetailView(meetingID: ref.id, highlightChunkID: ref.chunkID)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { sheet = nil } } }
            }
            .frame(minWidth: 720, minHeight: 620)
        }
    }

    private var emptyState: some View {
        VStack(spacing: compact ? 10 : 14) {
            Image(systemName: "sparkles")
                .font(.system(size: compact ? 26 : 38)).foregroundStyle(Theme.accent)
            Text(model.meetingID != nil ? "Ask about this call" : (compact ? "Ask your calls" : "Ask anything across your calls"))
                .font(compact ? .headline : .title2).bold().multilineTextAlignment(.center)
            if !compact {
                Text("Grounded answers with citations — it refuses rather than guess.")
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 8) {
                ForEach(suggestions, id: \.self) { s in
                    Button { ask(s) } label: {
                        Label(s, systemImage: "arrow.up.forward")
                            .font(compact ? .callout : .body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .frame(maxWidth: compact ? .infinity : 460)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(compact ? 16 : 24)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(messages) { m in
                        AskMessageView(message: m, onTapCite: { c in
                            if let onCite { onCite(c) } else { sheet = MeetingRef(id: c.meetingID, chunkID: c.chunkID) }
                        })
                            .id(m.id)
                    }
                }
                .padding(compact ? 14 : 20)
            }
            .onChange(of: messages.count) {
                if let last = messages.last { withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
    }

    private func ask(_ text: String) {
        let q = text; query = ""
        Task { await model.ask(q, env) }
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Ask anything across your meetings…", text: $query, axis: .vertical)
                .textFieldStyle(.plain).lineLimit(1...5)
                .onSubmit { ask(query) }
            Button { ask(query) } label: { Image(systemName: "arrow.up.circle.fill").font(.title) }
                .buttonStyle(.plain).foregroundStyle(Theme.accent)
                .disabled(busy || query.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.cardFill))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hairline))
        .padding(compact ? 12 : 16)
    }
}

struct AskMessageView: View {
    let message: AskMessage
    var onTapCite: ((Cite) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: message.role == .user ? "person.crop.circle.fill" : "sparkles")
                    .foregroundStyle(message.role == .user ? Color.secondary : Theme.accent)
                Text(message.role == .user ? "You" : "CallBrain").font(.subheadline).bold()
                if let s = message.status { Text(s).font(.caption).foregroundStyle(.secondary) }
                Spacer()
            }
            if message.pending {
                ReasoningTimeline(steps: message.steps)
            } else if message.role == .assistant {
                if !message.steps.isEmpty { ReasoningDisclosure(steps: message.steps) }
                MarkdownAnswerView(text: message.text).textSelection(.enabled)
            } else {
                Text(message.text).textSelection(.enabled)
            }
            if !message.citations.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Sources").font(.caption2.bold()).foregroundStyle(.tertiary).padding(.top, 2)
                    ForEach(message.citations) { c in
                        Button { onTapCite?(c) } label: {
                            HStack(spacing: 6) {
                                Text(c.tag).font(.caption.bold()).foregroundStyle(Theme.accent)
                                Text(c.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                Spacer(minLength: 4)
                                Image(systemName: "arrow.up.right.square").font(.caption2).foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 5).padding(.horizontal, 8)
                            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.accent.opacity(0.08)))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cbCard()
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

/// The live reasoning timeline (Phase 4.5) — each real pipeline step, the latest with a spinner.
struct ReasoningTimeline: View {
    let steps: [AskEngine.ReasoningStep]
    var body: some View {
        if steps.isEmpty {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Thinking…").foregroundStyle(.secondary) }
        } else {
            VStack(alignment: .leading, spacing: 9) {
                ForEach(Array(steps.enumerated()), id: \.element.id) { idx, step in
                    HStack(alignment: .top, spacing: 9) {
                        if idx == steps.count - 1 {
                            ProgressView().controlSize(.small).frame(width: 16, height: 16)
                        } else {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green.opacity(0.8))
                                .font(.caption).frame(width: 16, height: 16)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(step.title).font(.caption.weight(.medium))
                            Text(step.detail).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .transition(.opacity.combined(with: .move(edge: .leading)))
                }
            }
            .padding(.vertical, 2)
        }
    }
}

/// After answering, the timeline collapses into a "Thought for N steps" disclosure (Fireflies-style).
struct ReasoningDisclosure: View {
    let steps: [AskEngine.ReasoningStep]
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(.snappy) { expanded.toggle() } } label: {
                HStack(spacing: 5) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.caption2)
                    Image(systemName: "brain").font(.caption2)
                    Text("Reasoning · \(steps.count) steps").font(.caption)
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(steps) { step in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: step.icon).font(.caption2).foregroundStyle(Theme.accent)
                                .frame(width: 14)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(step.title).font(.caption2.weight(.medium))
                                Text(step.detail).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(.leading, 4).padding(.bottom, 2)
            }
        }
    }
}
