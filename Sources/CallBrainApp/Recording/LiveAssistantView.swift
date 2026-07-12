import Foundation
import SwiftUI
import CallBrainCore
import CallBrainAppCore

// MARK: - In-call assistant (the "I dozed off, catch me up" surface)
//
// Fireflies-calm, violet-accent, airy — the ASSISTANT is the hero (the founder's core need is a fast
// catch-up while live on a call), with the live transcript as a glanceable reference below it.
// Design tokens come from `Theme`; motion uses the shared `Theme.springy`/`Theme.smooth` curves so
// this surface settles like the rest of the app. Answers render as plain Text (no markdown flash),
// bubbles hug their content, every control is wired, and all colors are semantic (Dark/Light safe).

// MARK: Assistant panel (hero)

struct LiveAssistantPanel: View {
    let model: LiveAssistantModel?
    @State private var draft = ""

    private static let recapQuery =
        "What did they just say? Give me a quick, plain recap of the last thing that was said."

    var body: some View {
        if let model {
            VStack(alignment: .leading, spacing: 12) {
                header
                if model.messages.isEmpty {
                    Spacer(minLength: 0)   // keep the composer + actions pinned near the bottom when idle
                } else {
                    AssistantMessages(messages: model.messages,
                                      onSelectLane: { id, lane in model.showLane(lane, for: id) })
                        .frame(maxHeight: .infinity)
                        .transition(.opacity)
                }
                recapButton(model)
                if !model.suggestions.isEmpty {
                    suggestionChips(model)
                }
                inputRow(model)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: Theme.cardRadius)
                    .fill(Theme.accent.opacity(0.055))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius)
                    .strokeBorder(Theme.accent.opacity(0.18), lineWidth: 1)
            )
            .animation(Theme.springy, value: model.messages.count)
            .animation(Theme.smooth, value: model.suggestions)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Catch-up assistant")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Spacer(minLength: 0)
            // The header "thinking…" only shows until the FIRST answer (Fast) lands — once a usable
            // answer is on screen the panel shouldn't read as busy while the deeper answer streams in.
            if let model, isThinking(model) {
                Text("thinking…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
        }
    }

    /// Still "thinking" only while a turn is in flight AND nothing is on screen yet (no fast/smart token).
    private func isThinking(_ model: LiveAssistantModel) -> Bool {
        guard model.isAnswering, let last = model.messages.last, last.role == .assistant else { return false }
        return last.fastText.isEmpty && last.smartText.isEmpty
    }

    /// The #1 use case gets a first-class, full-width primary affordance — not a chip lost in a row.
    private func recapButton(_ model: LiveAssistantModel) -> some View {
        Button {
            model.send(Self.recapQuery)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 12, weight: .semibold))
                Text("What did they just say?")
                    .font(.system(size: 13, weight: .medium))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.accent.opacity(0.14)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.accent.opacity(0.28)))
            .foregroundStyle(Theme.accent)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.isAnswering)
        .opacity(model.isAnswering ? 0.5 : 1)
    }

    private func suggestionChips(_ model: LiveAssistantModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SUGGESTED")
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.tertiary)
            ChipFlowLayout(spacing: 6) {
                ForEach(Array(model.suggestions.enumerated()), id: \.offset) { item in
                    AssistantChip(title: item.element, disabled: model.isAnswering) {
                        model.send(item.element)
                    }
                }
            }
        }
        .opacity(model.isAnswering ? 0.55 : 1)
    }

    private func inputRow(_ model: LiveAssistantModel) -> some View {
        let canSend = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !model.isAnswering
        return HStack(spacing: 8) {
            TextField("Ask about this call…", text: $draft)
                .font(.system(size: 13))
                .textFieldStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 9).fill(Theme.cardFill))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.hairline))
                .disabled(model.isAnswering)
                .onSubmit { sendDraft(model) }
            Button { sendDraft(model) } label: {
                Group {
                    if model.isAnswering {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(canSend ? Theme.accent : Color.secondary.opacity(0.4))
                    }
                }
                .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .help("Send")
        }
    }

    private func sendDraft(_ model: LiveAssistantModel) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !model.isAnswering else { return }
        model.send(text)
        draft = ""
    }
}

// MARK: Assistant messages

private struct AssistantMessages: View {
    let messages: [LiveAssistantModel.Message]
    let onSelectLane: (Int, LiveAssistantModel.Message.Lane) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(messages) { message in
                        AssistantMessageBubble(message: message,
                                               onSelectLane: { lane in onSelectLane(message.id, lane) })
                            .id(message.id)
                    }
                }
                .padding(.vertical, 1)
            }
            .frame(maxHeight: .infinity)   // fill the tall panel so long answers are readable, not cramped
            .onAppear { scrollToLast(proxy, animated: false) }
            .onChange(of: messages.count) { _, _ in scrollToLast(proxy, animated: true) }
            .onChange(of: messages.last?.text) { _, _ in scrollToLast(proxy, animated: true) }
        }
    }

    private func scrollToLast(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let id = messages.last?.id else { return }
        if animated {
            withAnimation(Theme.smooth) { proxy.scrollTo(id, anchor: .bottom) }
        } else {
            proxy.scrollTo(id, anchor: .bottom)
        }
    }
}

private struct AssistantMessageBubble: View {
    let message: LiveAssistantModel.Message
    let onSelectLane: (LiveAssistantModel.Message.Lane) -> Void
    private var isUser: Bool { message.role == .user }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if isUser { Spacer(minLength: 40) }
            // User questions hug (~300pt bubble); the ANSWER uses the full panel width so a long
            // catch-up reads comfortably, not squeezed into a narrow column (founder: "hard to read when long").
            bubble
                .frame(maxWidth: isUser ? 300 : .infinity, alignment: isUser ? .trailing : .leading)
                .fixedSize(horizontal: false, vertical: true)
            if !isUser { Spacer(minLength: 0) }
        }
        .transition(.asymmetric(
            insertion: .opacity.combined(with: .move(edge: isUser ? .trailing : .leading)),
            removal: .opacity
        ))
    }

    @ViewBuilder private var bubble: some View {
        if isUser {
            Text(message.text)
                .font(.system(size: 13)).foregroundStyle(.primary).lineSpacing(1.5)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 11).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 11).fill(Theme.accent.opacity(0.16)))
        } else {
            AssistantAnswer(message: message, onSelectLane: onSelectLane)
                .padding(.horizontal, 11).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 11).fill(Theme.cardFill))
                .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Theme.hairline))
        }
    }
}

/// The assistant answer: a `Fast | Smart` tab (shown only when BOTH lanes are live), the active
/// lane's streamed/settled text, and a "Smarter answer ready" pulse on the Smart tab when it lands while
/// the user is still reading Fast. When one lane is unavailable the control is hidden (no dead tab).
private struct AssistantAnswer: View {
    let message: LiveAssistantModel.Message
    let onSelectLane: (LiveAssistantModel.Message.Lane) -> Void

    private typealias Lane = LiveAssistantModel.Message.Lane
    private typealias Phase = LiveAssistantModel.Message.Phase

    private var fastLive: Bool { message.fastPhase != .unavailable }
    private var smartLive: Bool { message.smartPhase != .unavailable }
    private var showTabs: Bool { fastLive && smartLive }
    /// Smart finished while the user is still on the Fast tab → nudge them there's a deeper answer.
    private var smartReady: Bool { message.smartPhase == .done && message.activeTab == .fast }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if showTabs { tabBar }
            laneBody(
                text: message.activeTab == .fast ? message.fastText : message.smartText,
                phase: message.activeTab == .fast ? message.fastPhase : message.smartPhase
            )
        }
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            tab(.fast, label: "Fast", icon: "bolt.fill")
            tab(.smart, label: "Smart", icon: "brain", showReadyDot: smartReady)
            Spacer(minLength: 0)
        }
    }

    private func tab(_ lane: Lane, label: String, icon: String, showReadyDot: Bool = false) -> some View {
        let selected = message.activeTab == lane
        return Button { onSelectLane(lane) } label: {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 9, weight: .semibold))
                Text(label).font(.system(size: 10, weight: .semibold))
                if showReadyDot {
                    Circle().fill(Theme.accent).frame(width: 5, height: 5)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .foregroundStyle(selected ? Theme.onAccent : Theme.accent)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(selected ? Theme.accent : Theme.accentSoft))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(lane == .fast ? "Instant local answer" : "Deeper answer")
        .animation(Theme.smooth, value: selected)
        .animation(Theme.smooth, value: showReadyDot)
    }

    @ViewBuilder private func laneBody(text: String, phase: Phase) -> some View {
        if text.isEmpty {
            // No text yet: a pending lane shows the typing indicator; a settled-but-empty lane (which the
            // model shouldn't produce — empty answers are marked unavailable) renders nothing, never an
            // empty bubble (audit HIGH defense-in-depth).
            if phase == .streaming || phase == .idle { TypingIndicator() } else { EmptyView() }
        } else if phase == .streaming {
            StreamingText(text)
        } else {
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .lineSpacing(1.5)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Streamed answer text with a soft blinking caret — the "it's writing for me right now" feel.
private struct StreamingText: View {
    let text: String
    @State private var caretOn = false
    init(_ text: String) { self.text = text }

    var body: some View {
        (Text(text) + Text(caretOn ? " ▌" : " ▌").foregroundColor(caretOn ? Theme.accent : Theme.accent.opacity(0.15)))
            .font(.system(size: 13))
            .foregroundStyle(.primary)
            .lineSpacing(1.5)
            .fixedSize(horizontal: false, vertical: true)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { caretOn = true }
            }
    }
}

/// Three-dot "thinking" indicator before the first token — never a modal spinner in the flow.
private struct TypingIndicator: View {
    @State private var pulse = false
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Theme.accent.opacity(0.55))
                    .frame(width: 5, height: 5)
                    .opacity(pulse ? 0.9 : 0.3)
                    .scaleEffect(pulse ? 1 : 0.8)
                    .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true).delay(Double(i) * 0.15), value: pulse)
            }
        }
        .frame(height: 15)
        .onAppear { pulse = true }
    }
}

// MARK: Live transcript peek (glanceable reference)

struct LiveTranscriptPeek: View {
    let lines: [LiveLine]

    // Consecutive same-speaker lines merged into a readable turn (Fireflies transcript style — never
    // a stuttering wall of one-liners). Capped to a recent window so the EAGER VStack below (macOS-26
    // LazyVStack-in-ScrollView beachballs a live call — see macos26-lazyvstack-scroll-hang) stays bounded.
    private var turns: [TranscriptTurn] { TranscriptTurn.group(lines.suffix(240)) }

    @State private var pinnedID: String?
    @State private var atBottom = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            ZStack {
                if turns.isEmpty { TranscriptEmptyState() } else { scroll }
            }
            .frame(height: 150)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius).fill(Theme.cardFill))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.hairline))
    }

    private var header: some View {
        HStack(spacing: 6) {
            LivePulse()
            Text("Live transcript")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if !atBottom {
                Label("scrolled up", systemImage: "arrow.down")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .transition(.opacity)
            }
        }
    }

    private var scroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(turns) { turn in
                        TranscriptTurnRow(turn: turn).id(turn.id)
                    }
                }
                .scrollTargetLayout()
                .padding(.trailing, 2)
            }
            .scrollPosition(id: $pinnedID, anchor: .bottom)
            .onAppear { jump(proxy, animated: false) }
            .onChange(of: pinnedID) { _, id in
                withAnimation(Theme.smooth) { atBottom = (id == nil || id == turns.last?.id) }
            }
            .onChange(of: turns) { old, new in
                // Only auto-follow if the user is already parked at the bottom (don't yank them up).
                guard atBottom || pinnedID == old.last?.id else { return }
                guard let last = new.last?.id else { return }
                withAnimation(Theme.smooth) { proxy.scrollTo(last, anchor: .bottom) }
                atBottom = true
            }
        }
    }

    private func jump(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let last = turns.last?.id else { return }
        proxy.scrollTo(last, anchor: .bottom)
        pinnedID = last
        atBottom = true
    }
}

/// One speaker's merged turn.
private struct TranscriptTurn: Identifiable, Equatable {
    let id: String
    let speaker: LiveSpeaker
    let text: String
    let confirmed: Bool

    /// Merge consecutive same-speaker lines; a turn is "unconfirmed" (still forming) if its last line is.
    static func group(_ lines: ArraySlice<LiveLine>) -> [TranscriptTurn] {
        var out: [TranscriptTurn] = []
        for line in lines {
            let text = line.text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            if let last = out.last, last.speaker == line.speaker {
                out[out.count - 1] = TranscriptTurn(id: last.id, speaker: last.speaker,
                                                    text: last.text + " " + text, confirmed: line.confirmed)
            } else {
                out.append(TranscriptTurn(id: line.id, speaker: line.speaker, text: text, confirmed: line.confirmed))
            }
        }
        return out
    }
}

private struct TranscriptTurnRow: View {
    let turn: TranscriptTurn

    // You keeps the primary violet accent; Them gets the curated, dark-tuned teal so the two speakers
    // read apart at a glance without a second raw "brand" accent. Both adapt to Dark/Light.
    private var speakerColor: Color { turn.speaker == .you ? Theme.accent : Theme.ventureTeal }

    var body: some View {
        HStack(alignment: .top, spacing: Space.s) {
            SpeakerAvatar(name: turn.speaker.rawValue, tint: speakerColor)
            VStack(alignment: .leading, spacing: 3) {
                Text(turn.speaker.rawValue)
                    .font(.cbCaption.weight(.semibold))
                    .foregroundStyle(speakerColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(turn.text)
                    .font(.cbBody)
                    .foregroundStyle(Theme.textPrimary)
                    .lineSpacing(1.5)
                    .opacity(turn.confirmed ? 1 : 0.5)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading) // bound width so long turns wrap, not clip
                    .padding(.horizontal, Space.m)
                    .padding(.vertical, Space.s)
                    .background(RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                        .fill(Theme.surfaceElevated))
                    .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                        .strokeBorder(speakerColor.opacity(0.22), lineWidth: 1))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TranscriptEmptyState: View {
    @State private var pulse = false
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.accent.opacity(pulse ? 0.95 : 0.45))
                .scaleEffect(pulse ? 1.05 : 0.95)
            Text("Listening to your call…")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: pulse)
        .onAppear { pulse = true }
    }
}

/// Small breathing "live" dot.
private struct LivePulse: View {
    @State private var on = false
    var body: some View {
        Circle().fill(Theme.accent)
            .frame(width: 7, height: 7)
            .opacity(on ? 1 : 0.4)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}

// MARK: Chips

private struct AssistantChip: View {
    let title: String
    let disabled: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(title).lineLimit(1).truncationMode(.tail)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(hovered ? Theme.accentSoft : Theme.cardFill))
                .overlay(Capsule().strokeBorder(hovered ? Theme.accent.opacity(0.35) : Theme.hairline))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovered = $0 }
        .animation(Theme.smooth, value: hovered)
    }
}

/// Simple left-to-right wrapping flow layout for the suggestion chips.
private struct ChipFlowLayout: Layout {
    let spacing: CGFloat
    init(spacing: CGFloat = 6) { self.spacing = spacing }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let maxWidth = proposal.width ?? .greatestFiniteMagnitude
        let p = ProposedViewSize(width: proposal.width, height: nil)
        var rowWidth: CGFloat = 0, rowHeight: CGFloat = 0, totalWidth: CGFloat = 0, totalHeight: CGFloat = 0
        for sv in subviews {
            let s = sv.sizeThatFits(p)
            if rowWidth > 0, rowWidth + spacing + s.width > maxWidth {
                totalWidth = max(totalWidth, rowWidth); totalHeight += rowHeight + spacing
                rowWidth = s.width; rowHeight = s.height
            } else {
                rowWidth += (rowWidth > 0 ? spacing : 0) + s.width; rowHeight = max(rowHeight, s.height)
            }
        }
        totalWidth = max(totalWidth, rowWidth); totalHeight += rowHeight
        return CGSize(width: proposal.width ?? totalWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for sv in subviews {
            let s = sv.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            if x > bounds.minX, x + s.width > bounds.maxX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            sv.place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                     proposal: ProposedViewSize(width: s.width, height: s.height))
            x += s.width + spacing; rowHeight = max(rowHeight, s.height)
        }
    }
}
