import Foundation

/// A persisted chat session (Phase 4.5). Backs the "Recents" rail so the founder can revisit/branch a
/// prior search. `meetingID == nil` is the global Ask surface; a set `meetingID` is a per-meeting AskFred
/// thread. Auto-titled from the first question.
public struct Conversation: Sendable, Equatable, Identifiable {
    public let id: String
    public var title: String
    public var meetingID: String?
    public var createdAt: Double
    public var updatedAt: Double
    public init(id: String, title: String, meetingID: String? = nil, createdAt: Double, updatedAt: Double) {
        self.id = id; self.title = title; self.meetingID = meetingID
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

/// One turn in a conversation. Assistant turns keep their citations (serialized) so reopening a thread
/// restores the tappable sources exactly.
public struct Message: Sendable, Equatable, Identifiable {
    public enum Role: String, Sendable, Equatable, Codable { case user, assistant }
    public let id: String
    public let conversationID: String
    public let role: Role
    public var text: String
    public var citations: [StoredCitation]
    public let createdAt: Double
    public init(id: String, conversationID: String, role: Role, text: String,
                citations: [StoredCitation] = [], createdAt: Double) {
        self.id = id; self.conversationID = conversationID; self.role = role
        self.text = text; self.citations = citations; self.createdAt = createdAt
    }
}

/// A citation as stored on a message (decoupled from the live retrieval `EvidenceRef`, and Codable so a
/// thread round-trips through the DB).
public struct StoredCitation: Sendable, Equatable, Codable {
    public let tag: String
    public let chunkID: String
    public let meetingID: String
    public let speaker: String?
    public let text: String
    public init(tag: String, chunkID: String, meetingID: String, speaker: String?, text: String) {
        self.tag = tag; self.chunkID = chunkID; self.meetingID = meetingID
        self.speaker = speaker; self.text = text
    }
}
