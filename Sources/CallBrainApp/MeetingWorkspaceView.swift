import SwiftUI
import CallBrainCore

/// The Fireflies-style meeting workspace (Phase 4.5): the call's content (Notes / Transcript) on the
/// left, a persistent **AskFred** chat docked on the right — scoped to THIS call, so every answer cites
/// inside this transcript. Used by the Meetings tab.
struct MeetingWorkspaceView: View {
    @Environment(AppEnvironment.self) private var env
    let meetingID: String
    @State private var focusChunkID: String?     // citation tap → scroll the transcript pane
    // Env-owned so an in-flight answer survives leaving + reopening this call's workspace.
    private var chat: ChatModel { env.meetingChat(meetingID) }

    var body: some View {
        // A width-respecting split: panes always sum to EXACTLY the available width. (HSplitView honored
        // its panes' greedy ideal widths and overflowed the navigation column, clipping the app sidebar
        // off the left edge — founder bug 2026-06-30.) AskFred docks at a sensible fraction, capped.
        GeometryReader { geo in
            let askWidth = min(440, max(320, geo.size.width * 0.36))
            HStack(spacing: 0) {
                MeetingDetailView(meetingID: meetingID, highlightChunkID: focusChunkID)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                askFred
                    .frame(width: askWidth)
            }
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
            AskPanel(model: chat, compact: true, onCite: { cite in
                // Same-citation re-tap still re-scrolls: clear then set so onChange fires.
                focusChunkID = nil
                DispatchQueue.main.async { focusChunkID = cite.chunkID }
            })
        }
        .background(Theme.cardFill.opacity(0.35))
    }
}
