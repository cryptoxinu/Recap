import SwiftUI
import CallBrainCore

/// The full Ask-AI surface: a left **Recents** rail (durable chat history — revisit/rename/delete) next
/// to the chat panel (Phase 4.5). New chats auto-save and appear in Recents.
struct AskView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var chat = ChatModel()
    @State private var renaming: Conversation?
    @State private var renameText = ""

    var body: some View {
        HStack(spacing: 0) {
            recentsRail
            Divider()
            AskPanel(model: chat)
        }
        .navigationTitle("Ask AI")
        .task { chat.refreshRecents(env) }
        .alert("Rename chat", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $renameText)
            Button("Save") { if let c = renaming { chat.rename(c.id, to: renameText, env) }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    private var recentsRail: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Recents").font(.headline)
                Spacer()
                Button { chat.newChat() } label: { Image(systemName: "square.and.pencil") }
                    .buttonStyle(.plain).foregroundStyle(Theme.accent)
                    .help("New chat")
            }
            .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 8)

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
                        ForEach(chat.recents) { conv in
                            recentRow(conv)
                        }
                    }
                    .padding(.horizontal, 8)
                }
            }
            Spacer()
        }
        .frame(width: 240)
        .background(Theme.cardFill.opacity(0.35))
    }

    private func recentRow(_ conv: Conversation) -> some View {
        let selected = chat.conversationID == conv.id
        return Button { chat.load(conv, env) } label: {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left").font(.caption).foregroundStyle(selected ? Theme.accent : .secondary)
                Text(conv.title).font(.callout).lineLimit(1)
                    .foregroundStyle(selected ? .primary : .secondary)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 7).padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Theme.accent.opacity(0.12) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Rename") { renaming = conv; renameText = conv.title }
            Button("Delete", role: .destructive) { chat.delete(conv.id, env) }
        }
    }
}
