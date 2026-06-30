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

    @Test("re-upserting a conversation (retitle/rescope) preserves its messages — no cascade wipe (gate MED)")
    func upsertPreservesMessages() throws {
        let store = try freshStore()
        try store.upsertConversation(Conversation(id: "c", title: "old", createdAt: 1, updatedAt: 1))
        try store.appendMessage(Message(id: "m1", conversationID: "c", role: .user, text: "hi", createdAt: 2))
        try store.appendMessage(Message(id: "m2", conversationID: "c", role: .assistant, text: "hello", createdAt: 3))
        // re-upsert SAME id with a new title — must NOT delete the messages
        try store.upsertConversation(Conversation(id: "c", title: "renamed", createdAt: 1, updatedAt: 9))
        #expect(try store.conversation(id: "c")?.title == "renamed")
        #expect(try store.messages(conversationID: "c").map(\.id) == ["m1", "m2"])   // preserved
    }

    @Test("deleteMeeting removes its chats AND scrubs its citation excerpts from other chats (gate HIGH)")
    func deleteMeetingScrubs() throws {
        let store = try freshStore()
        // a meeting with a chunk
        try store.saveMeeting(Meeting(id: "mt", title: "Sensitive call", date: "2026-06-29", source: .fireflies),
                              chunks: [Store.ChunkInput(chunkID: "mt_c0", meetingID: "mt", version: 0, seq: 0,
                                       speaker: "Max", tStart: 0, tEnd: 1, text: "secret roadmap details", contentHash: "h")])
        // a meeting-scoped chat + a global chat that cites the meeting
        try store.upsertConversation(Conversation(id: "cmtg", title: "AskFred", meetingID: "mt", createdAt: 1, updatedAt: 1))
        try store.appendMessage(Message(id: "m1", conversationID: "cmtg", role: .user, text: "what?", createdAt: 2))
        try store.upsertConversation(Conversation(id: "cglob", title: "global", createdAt: 1, updatedAt: 1))
        try store.appendMessage(Message(id: "m2", conversationID: "cglob", role: .assistant, text: "Per the call [S1].",
                                        citations: [StoredCitation(tag: "S1", chunkID: "mt_c0", meetingID: "mt",
                                                                   speaker: "Max", text: "secret roadmap details")], createdAt: 3))

        try store.deleteMeeting(id: "mt")

        #expect(try store.meeting(id: "mt") == nil)
        #expect(try store.conversation(id: "cmtg") == nil)              // meeting chat gone
        #expect(try store.messages(conversationID: "cmtg").isEmpty)     // its messages cascaded
        // global chat survives but its excerpt referencing the deleted call is scrubbed
        let glob = try store.messages(conversationID: "cglob")
        #expect(glob.count == 1)
        #expect(glob[0].citations.isEmpty)                              // no leaked transcript excerpt
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
