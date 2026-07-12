import Foundation

/// A task surfaced from a meeting (Phase 4). Either deterministically lifted from a Gemini-notes
/// `[Owner] …` line / "Action items" section, or LLM-extracted from a transcript (grounded in a chunk).
/// Persisted so the founder has a standing "what do I owe" view across every call — never re-derived.
public struct ActionItem: Sendable, Equatable, Identifiable {
    public enum Status: String, Sendable, Equatable, CaseIterable { case open, done }

    public let id: String
    public let meetingID: String
    public var owner: String?           // who owns it ("Alex", "Sam", or nil if unattributed)
    public var text: String
    public var status: Status
    public var sourceChunkID: String?   // grounding (for tap-to-source), when known
    public var tStart: Double?          // timestamp anchor in the source meeting, when known
    public var createdAt: Double

    public init(id: String, meetingID: String, owner: String? = nil, text: String,
                status: Status = .open, sourceChunkID: String? = nil, tStart: Double? = nil,
                createdAt: Double) {
        self.id = id; self.meetingID = meetingID; self.owner = owner; self.text = text
        self.status = status; self.sourceChunkID = sourceChunkID; self.tStart = tStart
        self.createdAt = createdAt
    }
}
