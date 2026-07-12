import Testing
import Foundation
@testable import CallBrainCore

/// Perfection plan Task 7.1a — ONE search API behind the ⌘K palette: meetings by title,
/// moments (chunk FTS), tasks, and chat threads, grouped and capped.
@Suite("Universal search (⌘K backend)")
struct UniversalSearchTests {

    private func seeded() throws -> Store {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("cb-usearch-\(UUID().uuidString).sqlite").path
        let store = try Store(path: path)
        let m1 = Meeting(id: "m1", title: "raw-file-name", date: "2026-06-29", source: .fireflies)
        try store.saveMeeting(m1, chunks: [
            Store.ChunkInput(chunkID: "c1", meetingID: "m1", version: 0, seq: 0, speaker: "Riley",
                             tStart: 30, tEnd: 50, text: "The billing pipeline ships Friday after the Render fix.",
                             contentHash: "b:c1"),
        ], tasks: [Store.TaskInput(id: "t1", owner: "Alex", text: "Review billing proposal", dedupeKey: "alex|review billing proposal")])
        try store.setMeetingIntelligence(id: "m1", aiTitle: "Billing & Render Sync", aiSummary: "Billing pipeline plan")
        let conv = Conversation(id: "conv1", title: "billing chat", meetingID: nil,
                                createdAt: 1_780_000_000, updatedAt: 1_780_000_000)
        try store.upsertConversation(conv)
        try store.appendMessage(Message(id: "msg1", conversationID: "conv1", role: .user,
                                        text: "what about billing", citations: [], createdAt: 1_780_000_001))
        return store
    }

    @Test("groups: meetings match ai_title, moments match chunk FTS, tasks + chats match text")
    func testGroupedResults() throws {
        let store = try seeded()
        let r = try store.searchEverything("billing")
        #expect(r.meetings.count == 1)
        #expect(r.meetings.first?.displayTitle == "Billing & Render Sync")
        #expect(r.moments.count == 1)
        #expect(r.moments.first?.meetingID == "m1")
        #expect(r.moments.first?.tStart == 30)
        #expect(r.tasks.count == 1)
        #expect(r.chats.count == 1)
    }

    @Test("empty and whitespace queries return nothing")
    func testEmptyQuery() throws {
        let store = try seeded()
        #expect(try store.searchEverything("").isEmpty)
        #expect(try store.searchEverything("   ").isEmpty)
    }

    @Test("special characters don't crash FTS (sanitizer path)")
    func testSpecialChars() throws {
        let store = try seeded()
        _ = try store.searchEverything(#"billing "AND* (render"#)   // must not throw
    }

    @Test("failed assistant markers do not count as answers or snippets")
    func testFailedMarkersDoNotCountAsAnswers() throws {
        let store = try seeded()
        try store.upsertConversation(Conversation(id: "failed", title: "failed only",
                                                  createdAt: 10, updatedAt: 10))
        try store.appendMessage(Message(id: "failed_user", conversationID: "failed", role: .user,
                                        text: "question", createdAt: 11))
        try store.appendMessage(Message(id: "failed_assistant", conversationID: "failed", role: .assistant,
                                        text: "Couldn't reach the AI engine.", createdAt: 12,
                                        provider: Store.failedTurnProviderMarker))

        try store.upsertConversation(Conversation(id: "mixed", title: "mixed", createdAt: 20, updatedAt: 20))
        try store.appendMessage(Message(id: "mixed_answer", conversationID: "mixed", role: .assistant,
                                        text: "Real answer", createdAt: 21))
        try store.appendMessage(Message(id: "mixed_failed", conversationID: "mixed", role: .assistant,
                                        text: "Couldn't reach the AI engine.", createdAt: 22,
                                        provider: Store.failedTurnProviderMarker))

        #expect(try store.conversationHasAnswer(id: "failed") == false)
        #expect(try store.conversationHasAnswer(id: "mixed") == true)
        #expect(try store.conversationSnippets(ids: ["failed", "mixed"]) == ["mixed": "Real answer"])
    }
}

/// Task 7.3 — list-row data helpers.
@Suite("Meetings list helpers (Task 7.3)")
struct MeetingListHelperTests {
    @Test("durations + people batch queries; task rows carry the AI title")
    func testHelpers() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("cb-listhelp-\(UUID().uuidString).sqlite").path
        let store = try Store(path: path)
        let m = Meeting(id: "m1", title: "raw-file", date: "2026-06-29", source: .fireflies)
        try store.saveMeeting(m, chunks: [Store.ChunkInput(
            chunkID: "c1", meetingID: "m1", version: 0, seq: 0, speaker: "T",
            tStart: 0, tEnd: 5, text: "hello", contentHash: "b:c1")],
            utterances: [Store.UtteranceInput(id: "u1", meetingID: "m1", version: 0, seq: 0,
                                              speaker: "Riley", personID: nil, speakerConfidence: nil,
                                              isInferredSpeaker: false, tStart: 0, tEnd: 1830,
                                              tsConfidence: "exact", text: "hello")],
            entities: [Store.EntityInput(name: "Riley", kind: "person", count: 9),
                       Store.EntityInput(name: "Priya", kind: "person", count: 4)],
            tasks: [Store.TaskInput(id: "t1", owner: "Alex", text: "Do the thing", dedupeKey: "alex|do the thing")])
        try store.setMeetingIntelligence(id: "m1", aiTitle: "Nice Title", aiSummary: nil)
        #expect(try store.meetingDurations(ids: ["m1"])["m1"] == 1830)
        #expect(try store.meetingPeople(ids: ["m1"])["m1"] == ["Riley", "Priya"])
        #expect(try store.tasks().first?.meetingTitle == "Nice Title")   // no raw filename leak
        #expect(try store.latestMeeting()?.displayTitle == "Nice Title")
    }
}
