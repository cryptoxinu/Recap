import SwiftUI
import CallBrainCore

/// The full Ask-AI surface: a left **Recents** rail (durable chat history — revisit/rename/delete) next
/// to the chat panel (Phase 4.5). New chats auto-save and appear in Recents.
struct AskView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var renaming: Conversation?
    @State private var renameText = ""
    @State private var railQuery = ""                 // Recents search (Task 7.5)
    // Shared, environment-owned chat so an in-flight answer survives leaving and returning to this tab.
    private var chat: ChatModel { env.askChat }

    var body: some View {
        HStack(spacing: 0) {
            recentsRail
            Divider()
            AskPanel(model: chat)
        }
        .navigationTitle("Ask AI")
        .onChange(of: env.pendingOpenChatID) { _, cid in   // palette while already mounted
            guard let cid else { return }
            env.pendingOpenChatID = nil
            openChat(cid)
        }
        .task {
            chat.refreshRecents(env)
            // ⌘K palette "chat" hit → load that thread (Task 7.1). Read the row from the STORE —
            // chat.recents may not be populated yet (gate MED: refreshRecents is async).
            if let cid = env.pendingOpenChatID {
                env.pendingOpenChatID = nil
                openChat(cid)
            }
            // Screenshot QA: CALLBRAIN_ASK=<question> auto-runs a query; CALLBRAIN_ASK2=<follow-up> then runs
            // a second turn that exercises conversation history (continuity).
            if let q = ProcessInfo.processInfo.environment["CALLBRAIN_ASK"], !q.isEmpty, chat.messages.isEmpty {
                await chat.ask(q, env)
                if let q2 = ProcessInfo.processInfo.environment["CALLBRAIN_ASK2"], !q2.isEmpty {
                    await chat.ask(q2, env)
                }
            }
            // Screenshot QA: CALLBRAIN_OPEN_RECENT=1 renders the most recent stored chat (no LLM call).
            if ProcessInfo.processInfo.environment["CALLBRAIN_OPEN_RECENT"] == "1", let c = chat.recents.first {
                chat.load(c, env)
            }
        }
        .alert("Rename chat", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $renameText)
            Button("Save") {
                // Trim + guard: a blank/whitespace-only title would write an unidentifiable Recents row.
                let title = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                if let c = renaming, !title.isEmpty { chat.rename(c.id, to: title, env) }
                renaming = nil
            }
            .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    /// Load a conversation by id straight from the store (palette routing, gate MED).
    private func openChat(_ cid: String) {
        let store = env.store
        Task {
            let conv = await Task.detached {
                ((try? store.globalConversations()) ?? []).first(where: { $0.id == cid })
            }.value
            if let conv { chat.load(conv, env) }
        }
    }

    private var recentsRail: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Recents").font(.cbHeadline).foregroundStyle(Theme.textPrimary)
                Spacer()
                Button { chat.newChat() } label: { Image(systemName: "square.and.pencil") }
                    .buttonStyle(.plain).foregroundStyle(Theme.accent)
                    .help("New chat")
            }
            .padding(.horizontal, Space.l).padding(.top, Space.l).padding(.bottom, Space.s)

            if chat.recents.count > 5 {
                HStack(spacing: Space.s) {
                    Image(systemName: "magnifyingglass").font(.cbCaption).foregroundStyle(Theme.textTertiary)
                    TextField("Search chats", text: $railQuery).textFieldStyle(.plain).font(.cbCallout)
                }
                .padding(.horizontal, Space.s).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).fill(Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).strokeBorder(Theme.hairline))
                .padding(.horizontal, Space.m).padding(.bottom, Space.xs)
            }

            if chat.recents.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath").font(.title3).foregroundStyle(.tertiary)
                    Text("Your past searches\nshow up here").font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity).padding(.top, 40)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(filteredRecents) { conv in
                            recentRow(conv)
                        }
                    }
                    .padding(.horizontal, 8)
                }
            }
            Spacer()
        }
        .frame(width: 240)
        .background(Theme.surfaceSunken)
    }

    /// Rail search filters titles AND snippet text (Task 7.5).
    private var filteredRecents: [Conversation] {
        let q = railQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return chat.recents }
        return chat.recents.filter {
            $0.title.lowercased().contains(q)
                || (chat.recentSnippets[$0.id]?.lowercased().contains(q) ?? false)
        }
    }

    /// "2h ago" / "Yesterday" / "Jun 28" from the thread's last activity.
    private static func relativeDate(_ epoch: Double) -> String {
        let d = Date(timeIntervalSince1970: epoch)
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .abbreviated
        if Date().timeIntervalSince(d) < 86_400 * 6 { return f.localizedString(for: d, relativeTo: Date()) }
        let df = DateFormatter(); df.dateFormat = "MMM d"
        return df.string(from: d)
    }

    /// One-line preview: markdown + citation tags stripped from the last answer.
    private func snippet(_ conv: Conversation) -> String? {
        guard let raw = chat.recentSnippets[conv.id] else { return nil }
        let s = raw
            .replacingOccurrences(of: #"\s?\[S\d+\]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[#*_`]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? nil : s
    }

    private func recentRow(_ conv: Conversation) -> some View {
        let selected = chat.conversationID == conv.id
        return Button { chat.load(conv, env) } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "bubble.left").font(.caption)
                    .foregroundStyle(selected ? Theme.accent : .secondary)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(conv.title).font(.callout).lineLimit(1)
                            .foregroundStyle(selected ? .primary : .secondary)
                        Spacer(minLength: 0)
                        Text(Self.relativeDate(conv.updatedAt)).font(.caption2).foregroundStyle(.tertiary)
                    }
                    if let snip = snippet(conv) {
                        Text(snip).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
            }
            .padding(.vertical, Space.s - 1).padding(.horizontal, Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).fill(selected ? Theme.accentSoft : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Rename") { renaming = conv; renameText = conv.title }
            Button("Delete", role: .destructive) { chat.delete(conv.id, env) }
        }
    }
}
