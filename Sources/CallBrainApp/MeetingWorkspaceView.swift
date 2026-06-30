import SwiftUI
import CallBrainCore

/// The Fireflies-style meeting workspace (Phase 4.5): the call's content (Notes / Transcript) on the
/// left, a persistent **AskFred** chat docked on the right — scoped to THIS call, so every answer cites
/// inside this transcript. Used by the Meetings tab.
struct MeetingWorkspaceView: View {
    @Environment(AppEnvironment.self) private var env
    let meetingID: String
    @State private var chat: ChatModel

    init(meetingID: String) {
        self.meetingID = meetingID
        _chat = State(initialValue: ChatModel(meetingID: meetingID))
    }

    var body: some View {
        HSplitView {
            MeetingDetailView(meetingID: meetingID)
                .frame(minWidth: 460, idealWidth: 720)
            askFred
                .frame(minWidth: 320, idealWidth: 380, maxWidth: 520)
        }
        .task { chat.refreshRecents(env) }
    }

    private var askFred: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").foregroundStyle(Theme.accent)
                Text("AskFred").font(.headline)
                Text("· this call").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !chat.messages.isEmpty {
                    Button { chat.newChat() } label: { Image(systemName: "square.and.pencil") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("New chat")
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            Divider()
            AskPanel(model: chat, compact: true)
        }
        .background(Theme.cardFill.opacity(0.35))
    }
}
