import SwiftUI
import CallBrainCore

/// Backs a chat surface and PERSISTS every turn to the Store (Phase 4.5), so the conversation shows up in
/// "Recents" and reopening it restores the full thread + citations. A `meetingID` scopes it to a single
/// call's AskFred (retrieval is hard-filtered to that meeting); nil is the global Ask surface.
@MainActor
@Observable
final class ChatModel {
    var messages: [AskMessage] = []
    var recents: [Conversation] = []
    var busy = false
    var saveFailed = false                  // true if a turn couldn't be persisted (shown in the UI)
    private(set) var conversationID: String?
    let meetingID: String?

    init(meetingID: String? = nil) { self.meetingID = meetingID }

    func refreshRecents(_ env: AppEnvironment) {
        recents = meetingID == nil
            ? (try? env.store.globalConversations()) ?? []
            : (try? env.store.conversations(meetingID: meetingID!)) ?? []
    }

    func newChat() { messages = []; conversationID = nil }

    func load(_ conv: Conversation, _ env: AppEnvironment) {
        conversationID = conv.id
        messages = ((try? env.store.messages(conversationID: conv.id)) ?? []).map { m in
            AskMessage(role: m.role == .user ? .user : .assistant, text: m.text,
                       citations: m.citations.map {
                           Cite(tag: $0.tag, meetingID: $0.meetingID, chunkID: $0.chunkID,
                                summary: "\($0.speaker ?? "Unknown") — \($0.text.prefix(80))…")
                       },
                       status: m.role == .assistant ? (m.citations.isEmpty ? "no sources" : "\(m.citations.count) sources") : nil)
        }
    }

    func rename(_ id: String, to title: String, _ env: AppEnvironment) {
        try? env.store.renameConversation(id: id, title: title); refreshRecents(env)
    }
    func delete(_ id: String, _ env: AppEnvironment) {
        try? env.store.deleteConversation(id: id)
        if conversationID == id { newChat() }
        refreshRecents(env)
    }

    func ask(_ text: String, _ env: AppEnvironment) async {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !busy else { return }
        busy = true
        defer { busy = false }

        // Ensure a conversation exists (auto-titled from the first question). nil = couldn't persist;
        // the chat still works in-memory but we DON'T pretend it's saved (Codex P4.5 gate HIGH).
        let convID = ensureConversation(firstQuestion: q, env)

        withAnimation(.snappy) { messages.append(AskMessage(role: .user, text: q, citations: [])) }
        if let convID { persist(.user, text: q, citations: [], conversationID: convID, env) }

        let pending = AskMessage(role: .assistant, text: "Thinking…", citations: [], pending: true)
        withAnimation(.snappy) { messages.append(pending) }
        let pid = pending.id

        // Live reasoning timeline: append each real pipeline step to the pending message.
        let onStep: AskEngine.StepHandler = { @MainActor [weak self] step in
            guard let self, let i = self.messages.firstIndex(where: { $0.id == pid }) else { return }
            withAnimation(.snappy) { self.messages[i].steps.append(step) }
        }

        do {
            let ans = meetingID == nil
                ? try await env.ask.ask(q, onStep: onStep)
                : try await env.ask.ask(q, inMeeting: meetingID!, onStep: onStep)
            let cites = ans.citations.map {
                Cite(tag: $0.tag, meetingID: $0.meetingID, chunkID: $0.chunkID,
                     summary: "\($0.speaker ?? "Unknown") — \($0.text.prefix(80))…")
            }
            if let i = messages.firstIndex(where: { $0.id == pid }) {
                withAnimation(.snappy) {
                    messages[i].text = ans.text
                    messages[i].citations = cites
                    messages[i].pending = false
                    messages[i].status = ans.status == .answered ? "\(cites.count) sources" : "no sources"
                    messages[i].provider = ans.provider
                }
            }
            let stored = ans.citations.map {
                StoredCitation(tag: $0.tag, chunkID: $0.chunkID, meetingID: $0.meetingID,
                               speaker: $0.speaker, text: $0.text)
            }
            if let convID { persist(.assistant, text: ans.text, citations: stored, conversationID: convID, env) }
            refreshRecents(env)
        } catch {
            if let i = messages.firstIndex(where: { $0.id == pid }) {
                messages[i].text = "Couldn't answer: \(error.localizedDescription)"
                messages[i].pending = false
            }
        }
    }

    // MARK: - persistence

    /// Create the conversation row; return its id ONLY if the insert succeeded (else nil + flag the
    /// failure, so we never show a "saved" chat that silently vanishes on relaunch — gate HIGH).
    private func ensureConversation(firstQuestion q: String, _ env: AppEnvironment) -> String? {
        if let id = conversationID { return id }
        let id = "conv_" + UUID().uuidString
        let now = Date().timeIntervalSince1970
        do {
            try env.store.upsertConversation(
                Conversation(id: id, title: Self.title(from: q), meetingID: meetingID, createdAt: now, updatedAt: now))
            conversationID = id
            return id
        } catch {
            saveFailed = true
            return nil
        }
    }

    private func persist(_ role: Message.Role, text: String, citations: [StoredCitation],
                         conversationID: String, _ env: AppEnvironment) {
        do {
            try env.store.appendMessage(Message(id: "msg_" + UUID().uuidString, conversationID: conversationID,
                                                role: role, text: text, citations: citations,
                                                createdAt: Date().timeIntervalSince1970))
        } catch { saveFailed = true }
    }

    static func title(from q: String) -> String {
        let t = q.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count <= 48 ? t : String(t.prefix(46)) + "…"
    }
}
