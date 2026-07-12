import SwiftUI
import AppKit
import CallBrainCore

struct Cite: Identifiable, Equatable, Hashable {
    let tag: String
    let meetingID: String
    let chunkID: String
    let summary: String
    var tStart: Double? = nil   // chunk start time (s) — Phase-4 hover cards + timestamp chips
    var id: String { tag + "|" + chunkID }
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
    var fellBack: Bool = false                  // did THIS answer come from the NON-primary (a real fallback)?
    var steps: [AskEngine.ReasoningStep] = []   // live agentic reasoning timeline (Phase 4.5)
    var followUps: [String] = []                // tappable next questions (Task 4.4)
    var nearMisses: [Cite] = []                 // refusal → closest moments to open (Task 8.3)
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
    @State private var isAtBottom = true      // scroll follows the stream ONLY at the bottom (Task 3.5)
    @State private var citePreview: Cite?     // citation tap → preview card first (Task 4.2)
    @State private var composerFocusToken = 0

    static let globalSuggestions = [
        "What are my action items this week?",
        "What did we decide in the last team sync?",
        "What is the status of our main project?",
        "What pricing did we agree on?",
    ]
    static let meetingSuggestions = [
        "Summarize this call",
        "What are the action items?",
        "What decisions were made?",
        "What should I follow up on?",
    ]
    /// Empty-state prompts generated from the ARCHIVE, not hardcoded strings (Task 4.4 — the
    /// audit's CONFIRMED-HIGH AskPanel:42 finding). Falls back to the static set until loaded.
    @State private var dynamicSuggestions: [String] = []
    private var suggestions: [String] {
        if model.meetingID != nil { return Self.meetingSuggestions }
        return dynamicSuggestions.isEmpty ? Self.globalSuggestions : dynamicSuggestions
    }

    private func loadDynamicSuggestions() async {
        guard model.meetingID == nil, dynamicSuggestions.isEmpty else { return }
        let store = env.store
        do {
            let built = await Task.detached { () -> [String] in
                var out: [String] = ["What are my action items this week?"]
                if let latest = try? store.meetings(fromYMD: "2000-01-01", toYMDExclusive: "2100-01-01",
                                                    limit: 10_000).max(by: { $0.date < $1.date }) {
                    out.append("Catch me up on \(latest.displayTitle)")
                }
                let open = (try? store.tasks(status: .open, limit: 500).count) ?? 0
                if open > 0 { out.append("Review my \(open) open action items — what's most urgent?") }
                if let person = try? store.topPersonEntity() {
                    out.append("What did \(person) say recently?")
                }
                return out
            }.value
            guard !Task.isCancelled else { return }   // the view's task died — don't publish stale
            self.dynamicSuggestions = built
        }
    }

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
                    .font(.caption).foregroundStyle(Theme.warning)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, compact ? 14 : 18).padding(.top, 4)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            inputBar
        }
        .animation(.smooth, value: model.saveFailed)
        .task { await loadDynamicSuggestions() }
        // Citation preview (Task 4.2): the quote proves itself in place; "Open in call" commits.
        .popover(item: $citePreview, arrowEdge: .top) { c in
            CitePreviewCard(cite: c) {
                citePreview = nil
                if let onCite { onCite(c) } else { sheet = MeetingRef(id: c.meetingID, chunkID: c.chunkID) }
            }
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
        VStack(spacing: compact ? Space.m : Space.l) {
            Image(systemName: CBIcon.ask)
                .font(.system(size: compact ? 26 : 34, weight: .light)).foregroundStyle(Theme.accent)
            Text(model.meetingID != nil ? "Ask about this call" : (compact ? "Ask your calls" : "Ask anything across your calls"))
                .font(compact ? .cbHeadline : .cbTitle).foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
            if !compact {
                Text("Grounded answers with citations — it refuses rather than guess.")
                    .font(.cbCallout).foregroundStyle(Theme.textSecondary)
            }
            VStack(spacing: Space.s) {
                ForEach(suggestions, id: \.self) { s in
                    Button { ask(s) } label: {
                        HStack(spacing: Space.s) {
                            Image(systemName: "arrow.up.forward").font(.cbCaption).foregroundStyle(Theme.accent)
                            Text(s).font(compact ? .cbCallout : .cbBody).foregroundStyle(Theme.textPrimary)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, Space.m).padding(.vertical, Space.s + 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).fill(Theme.surface))
                        .overlay(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).strokeBorder(Theme.hairline))
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: compact ? .infinity : 460)
            .padding(.top, Space.xs)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(compact ? Space.l : Space.xl)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // EAGER VStack, NOT LazyVStack: on macOS 26 a lazily-measured VStack of tall MarkdownUI
                // answers drives SwiftUI's layout engine into an exponential `_LazyLayoutViewCache`
                // sizeThatFits recursion → full main-thread beachball the moment a 2nd Q&A turn is added
                // (founder repro 2026-07-11, spindump CONFIRMED; same family as macos26-lazyvstack-scroll-hang).
                // A conversation is bounded (a handful of turns) so eager measurement is cheap + safe.
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(messages) { m in
                        // Only the MOST RECENT turn offers "Try again" — retryLast operates on the tail, so
                        // showing it on an earlier failed turn would retry the wrong question (audit HIGH).
                        // Citation taps open a PREVIEW CARD first (Task 4.2 — see the quote without
                        // leaving the answer); "Open in call" commits to the workspace.
                        messageRow(m)
                            .id(m.id)
                    }
                    // Dedicated 1pt bottom anchor — scrolling to THIS reliably reaches the true bottom
                    // even when the last answer is a tall, lazily-measured MarkdownUI view (founder:
                    // "can't scroll all the way down on long chats").
                    Color.clear.frame(height: 1).id(Self.bottomAnchorID)
                }
                .frame(maxWidth: compact ? .infinity : 760)          // reading width (Task 4.1)
                .frame(maxWidth: .infinity)                          // …centered in the pane
                .padding(compact ? 14 : 20)
            }
            // Autoscroll ONLY while the reader is at the bottom (Task 3.5): a streaming answer
            // must never hijack someone who scrolled up to re-read — they get a jump pill instead.
            // (Availability-gated: the package floor is macOS 14 for Core's sake; the app itself
            // ships on macOS 26, so the tracker is always live in practice.)
            .modifier(AtBottomTracker(isAtBottom: $isAtBottom))
            .overlay(alignment: .bottom) {
                if !isAtBottom && busy {
                    Button {
                        withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom) }
                    } label: {
                        Label("Jump to latest", systemImage: "arrow.down")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Capsule().fill(.thinMaterial))
                            .overlay(Capsule().strokeBorder(Theme.hairline))
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .onChange(of: messages.count) { scrollToEnd(proxy) }
            // The streaming answer grows IN PLACE (deltas append, steps append) without changing
            // the message count — follow that growth only while the reader is already at the end.
            .onChange(of: messages.last?.steps.count) { scrollToEnd(proxy) }
            .onChange(of: messages.last?.text) { scrollToEnd(proxy) }
            // Completion: anchor the finished answer's TOP so the reader starts at its beginning,
            // not staring at the tail of a wall of text (Task 3.5).
            .onChange(of: busy) { _, nowBusy in
                // Completion top-anchor ONLY if the reader was following along — someone who
                // scrolled up to re-read must not be yanked (Codex phase-3 MED).
                if !nowBusy, isAtBottom, let last = messages.last, last.role == .assistant {
                    withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(last.id, anchor: .top) }
                } else if nowBusy {
                    scrollToEnd(proxy)
                }
            }
        }
    }

    static let bottomAnchorID = "cb.transcript.bottom"

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        guard isAtBottom, !messages.isEmpty else { return }   // never hijack a reader who scrolled up
        if busy {
            // Streaming: UNANIMATED follow — ~15 flushes/sec of overlapping 0.25s ease
            // animations piled into a 3.4s main-thread stall (smoke watchdog, 2026-07-02).
            proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
        } else {
            withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom) }
        }
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

    @ViewBuilder private func messageRow(_ m: AskMessage) -> some View {
        let isLast = m.id == messages.last?.id
        let lastQ = messages.last(where: { $0.role == .user })?.text
        let explain: ((String) -> Void)? = model.meetingID.map { mid in
            { text in env.explainRequest = .init(text: String(text.prefix(600)), meetingID: mid) }
        }
        AskMessageView(message: m,
                       lastUserQuestion: lastQ,
                       researchAvailable: model.meetingID == nil,
                       selectedPrimary: env.providerPrimary,
                       onTapCite: { c in citePreview = c },
                       onRetry: isLast ? { model.retryLast(env) } : nil,
                       onFollowUp: isLast ? { q in ask(q) } : nil,
                       onRegenerate: isLast ? { model.regenerate(env) } : nil,
                       onExplainAnswer: explain)
    }

    private var inputBar: some View {
        VStack(spacing: 8) {
            HStack(alignment: .bottom, spacing: 10) {
                // Stays ENABLED while generating (Task 3.5): typing composes the next question;
                // only SEND is guarded. Fixed-height AppKit text view avoids SwiftUI intrinsic-size
                // loops seen after repeated Ask streams; ⌘L and People drafts still focus explicitly.
                ZStack(alignment: .topLeading) {
                    CBComposerTextView(text: $query, focusToken: composerFocusToken) { ask(query) }
                        .frame(height: 46)
                    if query.isEmpty {
                        Text(showsResearchToggle ? "Ask across your calls — or research the web…" : "Ask about this call…")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.top, 6)
                            .padding(.leading, 2)
                            .allowsHitTesting(false)
                    }
                }
                .frame(height: 46)
                .onChange(of: env.composerFocusRequest) { composerFocusToken += 1 }   // ⌘L (Task 7.2)
                .onChange(of: env.pendingAskDraft) { _, draft in                      // People page (8.2)
                    guard let draft else { return }
                    env.pendingAskDraft = nil
                    query = draft
                    composerFocusToken += 1
                }
                .onAppear {
                    composerFocusToken += 1
                    if let draft = env.pendingAskDraft {
                        env.pendingAskDraft = nil
                        query = draft
                        composerFocusToken += 1
                    }
                }
                .background(Button("") { composerFocusToken += 1 }.keyboardShortcut("l").hidden())
                Button { busy ? model.stop() : ask(query) } label: {
                    Image(systemName: busy ? "stop.circle.fill" : "arrow.up.circle.fill")
                        .font(.title)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .foregroundStyle(busy ? Theme.danger : Theme.accent)
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
                        .foregroundStyle(researchMode ? Theme.onAccent : Theme.textSecondary)
                        .animation(Theme.smooth, value: researchMode)
                        .padding(.horizontal, Space.s + 1).padding(.vertical, 5)
                        .background(Capsule().fill(researchMode ? Theme.accent : Theme.surface))
                        .overlay(Capsule().strokeBorder(researchMode ? .clear : Theme.hairline))
                    }
                    .buttonStyle(.plain)
                    .help("When on, Recap also searches the open web and clearly separates web findings from your calls.")
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

/// Wrapping row of tappable follow-up question chips (Task 4.4 — the Fireflies AskFred pattern).
struct FollowUpChips: View {
    let items: [String]
    var onTap: (String) -> Void
    var body: some View {
        // Wrapping FLOW (was a vertical VStack — one chip per line ate space): chips fill the row
        // then wrap, like Fireflies AskFred.
        FlowLayout(spacing: 6) {
            ForEach(items, id: \.self) { q in
                Button { onTap(q) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.turn.down.right").font(.caption2)
                        Text(q).font(.caption).lineLimit(1)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(Theme.accent.opacity(0.09)))
                    .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.25)))
                    .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 2)
    }
}

/// Sources as CARDS grouped by meeting (Task 4.3 — was a flat list of 80-char one-liners with
/// no call name or date, audit CONFIRMED "a dead list"). Auto-expanded when the answer draws on
/// ≤3 calls; header = `{title} · {date}`, rows = `[S1] (MM:SS) speaker — snippet`.
struct SourceCardsSection: View {
    @Environment(AppEnvironment.self) private var env
    let citations: [Cite]
    var onTapCite: ((Cite) -> Void)?
    @State private var expanded = false
    @State private var meetings: [String: Store.MeetingRow] = [:]

    /// Meeting order = first-citation order (mirrors the evidence grouping the model saw).
    private var groups: [(meetingID: String, cites: [Cite])] {
        var order: [String] = []
        var byMeeting: [String: [Cite]] = [:]
        for c in citations {
            if byMeeting[c.meetingID] == nil { order.append(c.meetingID) }
            byMeeting[c.meetingID, default: []].append(c)
        }
        return order.map { ($0, byMeeting[$0]!) }
    }

    /// Strip notes boilerplate the audit flagged in source rows ("## …", "Invited …").
    static func cleanSnippet(_ s: String) -> String {
        var t = s
        if let r = t.range(of: #"^(#+\s*|Invited\s.*?:\s*)"#, options: .regularExpression) {
            t.removeSubrange(r)
        }
        return t.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
    }

    var body: some View {
        let gs = groups
        let citationKey = citations.map(\.id).joined(separator: ",")
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(.snappy) { expanded.toggle() } } label: {
                HStack(spacing: 5) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.caption2)
                    Image(systemName: "quote.opening").font(.caption2)
                    Text("Sources · \(citations.count) from \(gs.count) call\(gs.count == 1 ? "" : "s")")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            if expanded {
                ForEach(gs, id: \.meetingID) { group in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 5) {
                            Image(systemName: "waveform").font(.caption2).foregroundStyle(Theme.accent)
                            Text(headerLine(group.meetingID))
                                .font(.caption.weight(.semibold)).lineLimit(1)
                        }
                        ForEach(group.cites) { c in
                            Button { onTapCite?(c) } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text(c.tag).font(.caption2.bold()).foregroundStyle(Theme.accent)
                                    if let t = c.tStart {
                                        Text(TimeCode.mmss(t)).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                                    }
                                    Text(Self.cleanSnippet(c.summary))
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    Spacer(minLength: 4)
                                    Image(systemName: "arrow.up.right.square").font(.caption2).foregroundStyle(.tertiary)
                                }
                                .padding(.vertical, 5).padding(.horizontal, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.accent.opacity(0.08)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Theme.cardFill))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.hairline))
                }
            }
        }
        .padding(.top, 4)
        .onChange(of: citationKey) {
            expanded = false   // founder: sources collapsed by default — expand via the header to inspect
            meetings = [:]
        }
        .task(id: expanded ? citationKey : "") {
            guard expanded else { return }
            let ids = gs.map(\.meetingID)
            let store = env.store
            meetings = await Task.detached { (try? store.meetings(ids: ids)) ?? [:] }.value
        }
    }

    private func headerLine(_ meetingID: String) -> String {
        guard let m = meetings[meetingID] else { return "…" }
        return "\(m.displayTitle) · \(MeetingsView.friendlyDate(m.date))"
    }
}

/// Citation preview card (Task 4.2): meeting · date · speaker · timestamp + the VERBATIM
/// passage, hydrated from the Store at render time (persisted rows carry only an 80-char
/// summary; hydration also survives merges — a missing chunk shows an honest fallback).
struct CitePreviewCard: View {
    @Environment(AppEnvironment.self) private var env
    let cite: Cite
    var onOpenInCall: () -> Void
    @State private var meetingLine = ""
    @State private var passage: String?
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(cite.tag).font(.caption.bold())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Theme.accent.opacity(0.14)))
                    .foregroundStyle(Theme.accent)
                Text(meetingLine.isEmpty ? "Loading…" : meetingLine)
                    .font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 12)
            }
            if let passage {
                ScrollView {
                    Text(passage)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
            } else if loaded {
                Label("This source is no longer available — the call may have been merged or deleted.",
                      systemImage: "questionmark.circle")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
            Button { onOpenInCall() } label: {
                Label("Open in call", systemImage: "arrow.up.forward.square")
            }
            .buttonStyle(.borderedProminent).tint(Theme.accent)
            .disabled(!loaded)
        }
        .padding(14)
        .frame(width: 380)
        .task {
            let store = env.store
            let (chunk, meeting) = await Task.detached { () -> (Store.ChunkHit?, Store.MeetingRow?) in
                let ch = (try? store.chunks(ids: [cite.chunkID]))?.first
                let m = try? store.meeting(id: ch?.meetingID ?? cite.meetingID)
                return (ch, m)
            }.value
            if let chunk {
                passage = chunk.text
                // Sources that carry NO per-turn timestamps (Meet CC captions, Gemini notes) store a
                // placeholder 0 — never render it as a fabricated "0:00" (citation-honesty contract). Those
                // chunks are cited by call + speaker only.
                let noTimestamps = ["gmeet_captions", "gmeet_gemini"].contains(meeting?.source ?? "")
                let ts = (noTimestamps ? nil : chunk.tStart).map { " · \(TimeCode.mmss($0))" } ?? ""
                let speaker = chunk.speaker.map { " · \($0)" } ?? ""
                meetingLine = "\(meeting?.displayTitle ?? "Unknown call") · \(meeting?.date ?? "")\(ts)\(speaker)"
            } else {
                meetingLine = meeting?.displayTitle ?? "Unknown call"
            }
            loaded = true
        }
    }
}

/// Tracks whether the reader is within ~60pt of the bottom of the scroll view (Task 3.5).
/// Pre-macOS-15 (impossible on the shipping app) it degrades to the old always-follow behavior.
struct AtBottomTracker: ViewModifier {
    @Binding var isAtBottom: Bool
    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.onScrollGeometryChange(for: Bool.self) { geo in
                geo.contentOffset.y + geo.containerSize.height >= geo.contentSize.height - 60
            } action: { _, atBottom in
                if isAtBottom != atBottom { isAtBottom = atBottom }
            }
        } else {
            content
        }
    }
}

struct AskMessageView: View {
    let message: AskMessage
    /// The question that produced this refusal (for reformulation chips, Task 8.3).
    var lastUserQuestion: String? = nil
    /// Web research is a GLOBAL-Ask capability (disabled in meeting-scoped AskFred) — gates the
    /// "Research the web" near-miss chip so it isn't a false affordance in a call (audit G1 MED).
    var researchAvailable: Bool = true
    /// The provider the user SELECTED (Settings/Home). If the answer came from the OTHER one, it was a
    /// transparent fallback (the selected engine was unavailable) — we say so instead of a silent switch.
    var selectedPrimary: ProviderID? = nil

    /// "what did we say last week about X" → "what did we say about X" (broaden-dates chip).
    static func stripDatePhrases(_ q: String) -> String {
        var out = q
        for p in ["this week", "last week", "past week", "this month", "last month", "past month",
                  "today", "yesterday"] {
            out = out.replacingOccurrences(of: p, with: "", options: .caseInsensitive)
        }
        out = out.replacingOccurrences(of: #"(?:in|from|during)\s+the\s+$"#, with: "", options: .regularExpression)
        return out.replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespaces)
    }
    var onTapCite: ((Cite) -> Void)?
    var onRetry: (() -> Void)? = nil
    var onFollowUp: ((String) -> Void)? = nil    // tap a suggested next question (Task 4.4)
    var onRegenerate: (() -> Void)? = nil        // re-ask with a fresh generation (Task 4.4)
    var onExplainAnswer: ((String) -> Void)? = nil  // "what did that answer mean?" (Task 4.5, in-meeting)
    @State private var sourcesExpanded = false   // call-citation list is collapsed by default
    @State private var started = Date()          // the "Thinking · Ns" counter's anchor
    @State private var hovering = false          // reveals the action row

    private var failed: Bool { message.status == "failed" }

    /// Plain-prose copy: citation chips stripped (no "[S3]" litter in an email or Slack paste).
    private var plainText: String {
        message.text
            .replacingOccurrences(of: #"\s?\[S\d+\]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: #"(?m)^#{1,3}\s"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?m)^---$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "`", with: "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // User turns carry NO header (Task 4.1: the trailing tinted bubble IS the "you"
            // signal, like iMessage/ChatGPT — the header's Spacer also forced full-width bubbles,
            // the audit's CONFIRMED never-hugs finding).
            if message.role == .assistant {
                HStack(spacing: Space.s) {
                    Image(systemName: CBIcon.assistant).foregroundStyle(Theme.accent)
                    Text("Recap").font(.cbBody.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                    if let s = message.status, s != "failed" { Text(s).font(.cbCaption).foregroundStyle(Theme.textSecondary) }
                    // Task 9.4 — the honest data-path badge: where did this answer's words come from? If the
                    // answer came from the OTHER engine than the one selected, say it was a fallback —
                    // directly answers "I have Codex on, why did it use Claude?".
                    if let p = message.provider {
                        // Per-answer fallback flag (stamped at ask time), NOT a current-settings compare —
                        // so flipping the primary no longer retro-badges old answers.
                        let fellBack = message.fellBack
                        let name: (ProviderID) -> String = { $0 == .codex ? "Codex" : "Claude" }
                        let other: ProviderID = p == .codex ? .claude : .codex
                        Label(fellBack ? "\(name(other)) was busy — answered with \(name(p))"
                                       : (p == .codex ? "Sent to Codex (OpenAI)" : "Sent to Claude (Anthropic)"),
                              systemImage: fellBack ? "arrow.triangle.branch" : "arrow.up.forward.circle")
                            .font(.caption2).foregroundStyle(fellBack ? Theme.warning : Theme.textSecondary)
                            .help(fellBack ? "\(name(other)) didn't respond in time, so Recap used \(name(p)) so you still got an answer — usually temporary."
                                           : "Your question + the retrieved call excerpts were sent to this AI to write the answer.")
                    } else if let st = message.status, st.first?.isNumber == true,
                              st.hasSuffix("moments"), !message.citations.isEmpty, !message.pending {
                        // "N cited/retrieved moments" ONLY — refusals and stopped streams get no badge.
                        // Only a COMPLETED grounded answer with no provider is truly local
                        // (gate MED: a stopped cloud stream has nil provider too — no badge there).
                        Label("On this Mac", systemImage: "lock.shield")
                            .font(.caption2).foregroundStyle(.secondary)
                            .help("Processed entirely on this Mac — nothing left your machine.")
                    }
                    Spacer()
                }
            }
            // While STREAMING, show sources above so the wait reads as evidence (Perplexity pattern).
            // For a COMPLETED answer they move to a quiet footer BELOW — answer-first (founder redesign).
            if message.pending, !failed, message.role == .assistant, !message.citations.isEmpty {
                SourceCardsSection(citations: message.citations, onTapCite: onTapCite)
            }
            Group {
                if message.pending {
                    // Streaming turn (Task 3.3/3.4): real steps, then LIVE tokens as they arrive.
                    VStack(alignment: .leading, spacing: 8) {
                        ReasoningTimeline(steps: message.steps)
                        if message.text.isEmpty || message.text == "Thinking…" {
                            // Pre-first-token: an honest counting timer beats a frozen label.
                            TimelineView(.periodic(from: started, by: 1)) { ctx in
                                Label("Thinking · \(max(0, Int(ctx.date.timeIntervalSince(started))))s",
                                      systemImage: "ellipsis")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .symbolEffect(.variableColor.iterative, options: .repeating)
                            }
                        } else {
                            // Render streaming tokens through the SAME MarkdownUI renderer as the finished
                            // answer — a raw `Text(message.text)` showed the model's literal markdown source
                            // (`##`, `**`, list `-`) mid-stream, then snapped to formatted on completion
                            // (founder 2026-07-11: "it shows ## // and bolds everything as it streams").
                            // MarkdownUI tolerates half-open markup, so partial `**bold` self-corrects when the
                            // closing token arrives, and the stream→final transition is now seamless.
                            MarkdownAnswerView(text: message.text, citations: message.citations, onTapCite: onTapCite)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .transition(.opacity)
                } else if failed {
                    // Honest failure treatment — an error card + a one-tap retry, NOT a normal answer bubble.
                    VStack(alignment: .leading, spacing: 8) {
                        Label(message.text, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.danger)
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
                    // Answer-first: the content leads; sources + "how it worked" move to the footer below.
                    MarkdownAnswerView(text: message.text, citations: message.citations, onTapCite: onTapCite)
                        .transition(.opacity)
                } else {
                    Text(message.text)
                }
            }
            .animation(.smooth(duration: 0.3), value: message.pending)
            // Post-answer affordances (Task 4.4): hover-revealed actions + follow-up chips.
            if message.role == .assistant, !message.pending, !failed {
                // Quiet meta footer BELOW the answer (answer-first): collapsed sources + how-it-worked.
                if !message.citations.isEmpty {
                    SourceCardsSection(citations: message.citations, onTapCite: onTapCite)
                }
                if !message.steps.isEmpty { ReasoningDisclosure(steps: message.steps) }
                HStack(spacing: 12) {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(plainText, forType: .string)
                    } label: { Label("Copy", systemImage: "doc.on.doc").font(.caption) }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .help("Copy the answer as plain text")
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(message.text, forType: .string)
                    } label: { Label("Copy Markdown", systemImage: "chevron.left.forwardslash.chevron.right").font(.caption) }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .help("Copy with markdown formatting")
                    if let onRegenerate {
                        Button { onRegenerate() } label: {
                            Label("Regenerate", systemImage: "arrow.clockwise").font(.caption)
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .help("Ask again with a fresh answer")
                    }
                    Spacer()
                }
                .opacity(hovering ? 1 : 0)
                .animation(.easeOut(duration: 0.15), value: hovering)
                if !message.followUps.isEmpty, let onFollowUp {
                    FollowUpChips(items: message.followUps) { onFollowUp($0) }
                }
                // Task 8.3 — a refusal is navigation, not a dead end: closest moments + reformulations.
                if !message.nearMisses.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("CLOSEST MOMENTS").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                        ForEach(message.nearMisses) { miss in
                            Button { onTapCite?(miss) } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "arrow.turn.down.right").font(.caption2)
                                    Text(miss.summary).font(.caption).lineLimit(1)
                                }
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(Capsule().fill(Theme.cardFill.opacity(0.8)))
                                .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                        if let onFollowUp, let last = lastUserQuestion {
                            HStack(spacing: 6) {
                                Button("Search all dates") { onFollowUp(Self.stripDatePhrases(last)) }
                                    .buttonStyle(.bordered).controlSize(.small)
                                // Only in GLOBAL Ask — research is disabled in meeting-scoped AskFred,
                                // so the chip was a false affordance there that produced an ungrounded
                                // "Research online:" query (audit G1 MED).
                                if researchAvailable {
                                    Button("Research the web") { onFollowUp("Research online: \(last)") }
                                        .buttonStyle(.bordered).controlSize(.small)
                                }
                            }
                        }
                    }
                    .padding(.top, 4)
                }
            }
        }
        .onHover { hovering = $0 }
        .modifier(BubbleTreatment(isUser: message.role == .user))
        .transition(.move(edge: .bottom).combined(with: .opacity))
        // Copy via right-click instead of drag-select: `.textSelection(.enabled)` on the answer text sent
        // SwiftUI's SelectionOverlay into an infinite intrinsic-content-size layout loop that beachballed
        // the app when the chat re-laid out to add another message (diagnosed via a live process sample).
        .contextMenu {
            if !message.text.isEmpty, !message.pending {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message.text, forType: .string)
                } label: { Label("Copy", systemImage: "doc.on.doc") }
                if message.role == .assistant, let onExplainAnswer {
                    Button { onExplainAnswer(message.text) } label: {
                        Label("Explain This Answer", systemImage: "questionmark.bubble")
                    }
                }
            }
        }
    }
}

/// User turns hug their content in a soft accent-tinted bubble and align trailing; assistant/answer turns
/// keep the neutral full-width card — so the thread is scannable for who said what (was a wall of identical
/// cards distinguished only by a tiny header).
private struct BubbleTreatment: ViewModifier {
    let isUser: Bool
    func body(content: Content) -> some View {
        if isUser {
            // Hugs its content (no inner Spacer anymore), capped ~70% so a one-liner reads as a
            // chat bubble and a long question wraps — never an edge-to-edge slab (Task 4.1).
            HStack(spacing: 0) {
                Spacer(minLength: 60)
                content
                    .padding(.vertical, 10).padding(.horizontal, 14)
                    .background(RoundedRectangle(cornerRadius: Theme.cardRadius).fill(Theme.accentSoft))
                    .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.accent.opacity(0.15)))
            }
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
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
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
                    Text("How it worked this out · \(steps.count) steps").font(.caption)   // was a "brain" glyph (AI slop)
                }
                .foregroundStyle(Theme.textTertiary)
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
