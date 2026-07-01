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
    var provider: ProviderID? = nil             // which subscription answered (Phase 5 badge)
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
    @State private var researchMode = false   // globe toggle: also search the open web (global chat only)

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
            Group {
                if messages.isEmpty {
                    emptyState.transition(.opacity.combined(with: .scale(scale: 0.98)))
                } else {
                    transcript.transition(.opacity)
                }
            }
            .animation(.smooth(duration: 0.3), value: messages.isEmpty)
            if model.saveFailed {
                Label("Couldn't save this chat — check disk space or relaunch.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, compact ? 14 : 18).padding(.top, 4)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            inputBar
        }
        .animation(.smooth, value: model.saveFailed)
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
                        // Only the MOST RECENT turn offers "Try again" — retryLast operates on the tail, so
                        // showing it on an earlier failed turn would retry the wrong question (audit HIGH).
                        AskMessageView(message: m, onTapCite: { c in
                            if let onCite { onCite(c) } else { sheet = MeetingRef(id: c.meetingID, chunkID: c.chunkID) }
                        }, onRetry: m.id == messages.last?.id ? { model.retryLast(env) } : nil)
                            .id(m.id)
                    }
                }
                .padding(compact ? 14 : 20)
            }
            .onChange(of: messages.count) { scrollToEnd(proxy) }
            // The streaming answer grows IN PLACE (reasoning steps append, then "Thinking…" → full answer)
            // without changing the message count — track that growth so a long answer stays in view.
            .onChange(of: messages.last?.steps.count) { scrollToEnd(proxy) }
            .onChange(of: messages.last?.text) { scrollToEnd(proxy) }
            .onChange(of: busy) { scrollToEnd(proxy) }
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        if let last = messages.last { withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(last.id, anchor: .bottom) } }
    }

    private func ask(_ text: String) {
        // Trim newlines too so the guard matches ChatModel.send's trim — a newline-only field is a no-op.
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !busy else { return }
        query = ""
        model.send(q, env, research: researchMode)   // background-survivable; Stop cancels it
    }

    /// Global chat only: a globe toggle that also researches the open web for this question.
    private var showsResearchToggle: Bool { model.meetingID == nil }

    private var inputBar: some View {
        VStack(spacing: 8) {
            HStack(alignment: .bottom, spacing: 10) {
                TextField(showsResearchToggle ? "Ask across your calls — or research the web…" : "Ask about this call…",
                          text: $query, axis: .vertical)
                    .textFieldStyle(.plain).lineLimit(1...5)
                    .onSubmit { ask(query) }
                    .disabled(busy)
                Button { busy ? model.stop() : ask(query) } label: {
                    Image(systemName: busy ? "stop.circle.fill" : "arrow.up.circle.fill")
                        .font(.title)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .foregroundStyle(busy ? .red : Theme.accent)
                .disabled(!busy && query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help(busy ? "Stop generating" : "Ask")
                .animation(Theme.smooth, value: busy)
            }
            if showsResearchToggle {
                HStack(spacing: 8) {
                    Button { researchMode.toggle() } label: {
                        HStack(spacing: 5) {
                            Image(systemName: researchMode ? "globe.americas.fill" : "globe")
                            Text("Research the web")
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(researchMode ? .white : .secondary)
                        .animation(Theme.smooth, value: researchMode)
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(Capsule().fill(researchMode ? Theme.accent : Theme.cardFill))
                        .overlay(Capsule().strokeBorder(researchMode ? .clear : Theme.hairline))
                    }
                    .buttonStyle(.plain)
                    .help("When on, CallBrain also searches the open web and clearly separates web findings from your calls.")
                    Spacer()
                }
            }
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
    var onRetry: (() -> Void)? = nil
    @State private var sourcesExpanded = false   // call-citation list is collapsed by default

    private var failed: Bool { message.status == "failed" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: message.role == .user ? "person.crop.circle.fill" : "sparkles")
                    .foregroundStyle(message.role == .user ? Color.secondary : Theme.accent)
                Text(message.role == .user ? "You" : "CallBrain").font(.subheadline).bold()
                if let s = message.status, s != "failed" { Text(s).font(.caption).foregroundStyle(.secondary) }
                if let p = message.provider {
                    Text("· \(p == .codex ? "Codex" : "Claude")")
                        .font(.caption2).foregroundStyle(Theme.accent)
                }
                Spacer()
            }
            Group {
                if message.pending {
                    ReasoningTimeline(steps: message.steps).transition(.opacity)
                } else if failed {
                    // Honest failure treatment — an error card + a one-tap retry, NOT a normal answer bubble.
                    VStack(alignment: .leading, spacing: 8) {
                        Label(message.text, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let onRetry {
                            Button { onRetry() } label: {
                                Label("Try again", systemImage: "arrow.clockwise").font(.callout)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .transition(.opacity)
                } else if message.role == .assistant {
                    VStack(alignment: .leading, spacing: 8) {
                        if !message.steps.isEmpty { ReasoningDisclosure(steps: message.steps) }
                        MarkdownAnswerView(text: message.text, citations: message.citations, onTapCite: onTapCite)
                            .textSelection(.enabled)
                    }
                    .transition(.opacity)
                } else {
                    Text(message.text).textSelection(.enabled)
                }
            }
            .animation(.smooth(duration: 0.3), value: message.pending)
            if !failed, !message.citations.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Button { withAnimation(.snappy) { sourcesExpanded.toggle() } } label: {
                        HStack(spacing: 5) {
                            Image(systemName: sourcesExpanded ? "chevron.down" : "chevron.right").font(.caption2)
                            Image(systemName: "quote.opening").font(.caption2)
                            Text("Sources · \(message.citations.count)").font(.caption)
                        }
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    if sourcesExpanded {
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
                }
                .padding(.top, 4)
            }
        }
        .modifier(BubbleTreatment(isUser: message.role == .user))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

/// User turns hug their content in a soft accent-tinted bubble and align trailing; assistant/answer turns
/// keep the neutral full-width card — so the thread is scannable for who said what (was a wall of identical
/// cards distinguished only by a tiny header).
private struct BubbleTreatment: ViewModifier {
    let isUser: Bool
    func body(content: Content) -> some View {
        if isUser {
            content
                .padding(.vertical, 10).padding(.horizontal, 14)
                .background(RoundedRectangle(cornerRadius: Theme.cardRadius).fill(Theme.accentSoft))
                .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.accent.opacity(0.15)))
                .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .cbCard()
        }
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
