import Testing
import Foundation
@testable import CallBrainCore

@Suite("Store: durable conversations + messages")
struct ConversationStoreTests {

    private func freshStore() throws -> Store {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("cb-conv-\(UUID().uuidString).sqlite").path
        return try Store(path: path)
    }

    @Test("append messages → round-trip with citations; conversation bumps to newest activity")
    func roundTrip() throws {
        let store = try freshStore()
        try store.upsertConversation(Conversation(id: "c1", title: "Render question", createdAt: 100, updatedAt: 100))
        try store.appendMessage(Message(id: "m1", conversationID: "c1", role: .user,
                                        text: "What did Travis say about Render?", createdAt: 110))
        let cites = [StoredCitation(tag: "S1", chunkID: "ck1", meetingID: "mt1", speaker: "Travis", text: "Render pricing dropped.")]
        try store.appendMessage(Message(id: "m2", conversationID: "c1", role: .assistant,
                                        text: "Travis said pricing dropped [S1].", citations: cites, createdAt: 120))

        let msgs = try store.messages(conversationID: "c1")
        #expect(msgs.map(\.id) == ["m1", "m2"])
        #expect(msgs[1].role == .assistant)
        #expect(msgs[1].citations == cites)                       // citations round-trip
        // updated_at bumped to the latest message time
        #expect(try store.conversation(id: "c1")?.updatedAt == 120)
    }

    @Test("global vs meeting-scoped Recents are separated; newest first")
    func scoping() throws {
        let store = try freshStore()
        try store.upsertConversation(Conversation(id: "g1", title: "Global older", createdAt: 1, updatedAt: 1))
        try store.upsertConversation(Conversation(id: "g2", title: "Global newer", createdAt: 2, updatedAt: 5))
        try store.upsertConversation(Conversation(id: "mtg", title: "In a meeting", meetingID: "mt1", createdAt: 3, updatedAt: 9))

        #expect(try store.globalConversations().map(\.id) == ["g2", "g1"])   // meeting thread excluded, newest first
        #expect(try store.conversations(meetingID: "mt1").map(\.id) == ["mtg"])
    }

    @Test("rename + delete (messages cascade)")
    func renameDelete() throws {
        let store = try freshStore()
        try store.upsertConversation(Conversation(id: "c", title: "old", createdAt: 1, updatedAt: 1))
        try store.appendMessage(Message(id: "m", conversationID: "c", role: .user, text: "hi", createdAt: 2))
        try store.renameConversation(id: "c", title: "new")
        #expect(try store.conversation(id: "c")?.title == "new")
        try store.deleteConversation(id: "c")
        #expect(try store.conversation(id: "c") == nil)
        #expect(try store.messages(conversationID: "c").isEmpty)   // cascade
    }
}
