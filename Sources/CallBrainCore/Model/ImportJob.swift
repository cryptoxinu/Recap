import Foundation

/// A durable record of one import attempt (Phase 2). Persisted so a long archive backfill survives
/// relaunch/crash, and so the Import Queue can show what's pending, done, failed, or needs a human look.
/// AI-resolved imports land in `.needsReview` so the founder can confirm the model structured it right.
public struct ImportJob: Sendable, Equatable, Identifiable {
    public enum State: String, Sendable, Equatable, CaseIterable {
        case queued, running, done, needsReview, failed
    }

    /// How to (re)run this job — persisted so a queued/interrupted job survives relaunch (durable queue).
    public enum PayloadKind: String, Sendable, Equatable { case file, paste }

    public let id: String
    public var sourceName: String          // filename, or "Pasted text"
    public var state: State
    public var format: String?             // resolved AIImporter.Format raw value
    public var usedAI: Bool
    public var meetingID: String?
    public var title: String?
    public var chunkCount: Int
    public var message: String?            // error detail, or a review note
    public var createdAt: Double           // epoch seconds
    public var payloadKind: PayloadKind?   // file → `payload` is an absolute path; paste → `payload` is the text
    public var payload: String?

    public init(id: String, sourceName: String, state: State = .queued, format: String? = nil,
                usedAI: Bool = false, meetingID: String? = nil, title: String? = nil,
                chunkCount: Int = 0, message: String? = nil, createdAt: Double,
                payloadKind: PayloadKind? = nil, payload: String? = nil) {
        self.id = id; self.sourceName = sourceName; self.state = state; self.format = format
        self.usedAI = usedAI; self.meetingID = meetingID; self.title = title
        self.chunkCount = chunkCount; self.message = message; self.createdAt = createdAt
        self.payloadKind = payloadKind; self.payload = payload
    }
}
