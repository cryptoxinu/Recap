import Foundation

/// Call Corpus export (Part B) — the fully-resolved, serialization-ready view of ONE call. Pure value
/// type: assembled from the Store off-main, then handed to `CallCorpusFormatter`. No Store, no I/O here,
/// so the formatting is deterministic and unit-testable against goldens.
public struct CorpusCall: Sendable, Equatable {
    public let id: String
    public let title: String
    /// The raw source/file title, only when it differs from `title` (an AI-polished title).
    public let originalTitle: String?
    public let date: String                // "YYYY-MM-DD"
    public let startTime: String?          // ISO8601, if known (passed through from the Store verbatim)
    public let durationSeconds: Int?
    public let source: String
    public let company: String?
    public let category: String?
    public let categoryConfidence: Double?
    public let summarySource: String?
    public let participants: [String]
    public let oneLiner: String?
    public let userNotes: String?
    public let summary: String?
    public let actionItems: [CorpusActionItem]
    public let transcript: [CorpusTurn]
    public let contentHash: String?
    /// `meetings.updated_at` — the cheap change-detection key the exporter's ledger compares.
    public let updatedAt: String

    public init(id: String, title: String, originalTitle: String? = nil, date: String,
                startTime: String? = nil, durationSeconds: Int? = nil, source: String,
                company: String? = nil, category: String? = nil, categoryConfidence: Double? = nil,
                summarySource: String? = nil, participants: [String] = [], oneLiner: String? = nil,
                userNotes: String? = nil, summary: String? = nil, actionItems: [CorpusActionItem] = [],
                transcript: [CorpusTurn] = [], contentHash: String? = nil, updatedAt: String) {
        self.id = id; self.title = title; self.originalTitle = originalTitle; self.date = date
        self.startTime = startTime; self.durationSeconds = durationSeconds; self.source = source
        self.company = company; self.category = category; self.categoryConfidence = categoryConfidence
        self.summarySource = summarySource; self.participants = participants; self.oneLiner = oneLiner
        self.userNotes = userNotes; self.summary = summary; self.actionItems = actionItems
        self.transcript = transcript; self.contentHash = contentHash; self.updatedAt = updatedAt
    }
}

/// One action item — owner (nullable), text, and status ("open" | "done").
public struct CorpusActionItem: Codable, Sendable, Equatable {
    public let owner: String?
    public let text: String
    public let status: String
    public init(owner: String?, text: String, status: String) {
        self.owner = owner; self.text = text; self.status = status
    }
}

/// One transcript turn — start seconds (nullable), speaker (nullable), whether the speaker is an
/// inferred guess, and the text.
public struct CorpusTurn: Sendable, Equatable {
    public let t: Double?
    public let speaker: String?
    public let inferred: Bool
    public let text: String
    public init(t: Double?, speaker: String?, inferred: Bool, text: String) {
        self.t = t; self.speaker = speaker; self.inferred = inferred; self.text = text
    }
}

/// One line of `index.jsonl` — the bot's cheap corpus-scan target AND Recap's own export ledger
/// (content_hash + updated_at + export_hash per id decide skips/rewrites/prunes). Serialized/parsed via
/// `.convert(To/From)SnakeCase`, so property names stay camelCase here and snake_case on disk.
public struct CorpusIndexEntry: Codable, Sendable, Equatable {
    public let id: String
    public let file: String          // "calls/<stem>.md"
    public let json: String          // "calls/<stem>.json"
    public let date: String
    public let title: String
    public let source: String
    public let company: String?
    public let category: String?
    public let participants: [String]
    public let durationSeconds: Int?
    public let actionItemCount: Int
    public let oneLiner: String?
    public let contentHash: String?
    public let updatedAt: String
    public let exportHash: String
    public let exportedAt: String

    public init(id: String, file: String, json: String, date: String, title: String, source: String,
                company: String?, category: String?, participants: [String], durationSeconds: Int?,
                actionItemCount: Int, oneLiner: String?, contentHash: String?, updatedAt: String,
                exportHash: String, exportedAt: String) {
        self.id = id; self.file = file; self.json = json; self.date = date; self.title = title
        self.source = source; self.company = company; self.category = category
        self.participants = participants; self.durationSeconds = durationSeconds
        self.actionItemCount = actionItemCount; self.oneLiner = oneLiner; self.contentHash = contentHash
        self.updatedAt = updatedAt; self.exportHash = exportHash; self.exportedAt = exportedAt
    }
}
