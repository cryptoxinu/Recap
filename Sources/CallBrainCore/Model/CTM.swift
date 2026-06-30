import Foundation

// MARK: - Canonical Transcript Model (CTM)
//
// The single representation every source (Fathom, Fireflies, Cluely, Google Meet,
// SRT/VTT) normalizes into. See docs/ARCHITECTURE.md §6.3. All types are immutable
// value types: `let` for identity, `var` for fields that normalization fills in.
// Everything is `Codable` (persisted + crosses actor boundaries) and `Sendable`
// (Swift 6 strict concurrency).

/// Where a meeting's transcript originated. Drives parsing, dedupe trust order, and
/// citation labeling. Raw values match the `meetings.source` column taxonomy in the DDL.
public enum MeetingSource: String, Codable, Sendable, CaseIterable {
    case fathom
    case fireflies
    case cluely
    case gmeetGemini = "gmeet_gemini"   // Google Meet transcript Doc (Gemini / Workspace)
    case gmeetLocal  = "gmeet_local"    // raw Meet video transcribed on-device (WhisperKit + FluidAudio)
    case gmeetCloud  = "gmeet_cloud"    // raw Meet video upgraded to cloud transcription
    case srtVtt      = "srt_vtt"
    case paste
    case manual
}

/// Honesty ladder for how precise a timestamp is. A citation never fabricates a `00:00`;
/// when no real timestamp exists it is cited by meeting + speaker + sequence position.
public enum TimestampConfidence: String, Codable, Sendable {
    case exact      // explicit per-turn timestamps (Fireflies, Fathom)
    case coarse     // sparse anchors (Meet Doc ~5-min markers)
    case derived    // inferred from word alignment (local transcription)
    case none       // no timestamp available (some Cluely notes)
}

/// The atomic unit of a transcript: one continuous speaker turn (after merge), ordered by `tStart`.
public struct Utterance: Codable, Sendable, Equatable, Identifiable {
    public let id: String                 // e.g. "u_000123"
    public let meetingID: String
    public let version: Int               // transcript version (local v0 is immutable)
    public let seq: Int                   // order within the meeting/version
    public var personID: String?          // resolved canonical person; nil when unknown
    public var speakerRaw: String         // verbatim label as it appeared in the source
    public var speakerConfidence: Double? // 1.0 for explicit labels; diarization posterior otherwise
    public var tStart: Double             // seconds from meeting start
    public var tEnd: Double
    public var text: String
    public var isInferredSpeaker: Bool    // true when the speaker came from diarization, not an explicit label
    public var tsConfidence: TimestampConfidence

    public init(id: String, meetingID: String, version: Int, seq: Int, personID: String? = nil,
                speakerRaw: String, speakerConfidence: Double? = nil, tStart: Double, tEnd: Double,
                text: String, isInferredSpeaker: Bool, tsConfidence: TimestampConfidence) {
        self.id = id; self.meetingID = meetingID; self.version = version; self.seq = seq
        self.personID = personID; self.speakerRaw = speakerRaw; self.speakerConfidence = speakerConfidence
        self.tStart = tStart; self.tEnd = tEnd; self.text = text
        self.isInferredSpeaker = isInferredSpeaker; self.tsConfidence = tsConfidence
    }
}

/// A participant reference on a meeting (resolved to a canonical person where possible).
public struct ParticipantRef: Codable, Sendable, Equatable {
    public let personID: String
    public var rawLabel: String
    public var role: String?              // "speaker" | "owner" | …

    public init(personID: String, rawLabel: String, role: String? = nil) {
        self.personID = personID; self.rawLabel = rawLabel; self.role = role
    }
}

/// A meeting (the hub). Summary/derived JSON lives in the DB; this is the in-memory core.
public struct Meeting: Codable, Sendable, Equatable, Identifiable {
    public let id: String                 // UUIDv7 (time-ordered, merge-safe)
    public var title: String
    public var date: String               // "YYYY-MM-DD" — local calendar day of the call
    public var startedAt: Date?           // precise start, if known
    public var durationSeconds: Int?
    public var source: MeetingSource
    public var company: String?
    public var participants: [ParticipantRef]
    public var contentFingerprint: String? // "blake3:…" of normalized text (same-meeting dedupe key)
    public var fileHash: String?           // "blake3:…" of source bytes (exact re-drop dedupe key)

    public init(id: String, title: String, date: String, startedAt: Date? = nil,
                durationSeconds: Int? = nil, source: MeetingSource, company: String? = nil,
                participants: [ParticipantRef] = [], contentFingerprint: String? = nil,
                fileHash: String? = nil) {
        self.id = id; self.title = title; self.date = date; self.startedAt = startedAt
        self.durationSeconds = durationSeconds; self.source = source; self.company = company
        self.participants = participants; self.contentFingerprint = contentFingerprint
        self.fileHash = fileHash
    }
}

/// Everything needed to render a tappable, verifiable citation back to the transcript.
public struct Citation: Codable, Sendable, Equatable {
    public let chunkID: String
    public let meetingID: String
    public let meetingTitle: String
    public let meetingDate: String        // "YYYY-MM-DD"
    public let speaker: String
    public let tStart: Double?
    public let tEnd: Double?
    public let source: MeetingSource
    public var alsoInSources: [MeetingSource] // other sources the same content appears in (dedupe fold)
    public let tsConfidence: TimestampConfidence

    public init(chunkID: String, meetingID: String, meetingTitle: String, meetingDate: String,
                speaker: String, tStart: Double?, tEnd: Double?, source: MeetingSource,
                alsoInSources: [MeetingSource] = [], tsConfidence: TimestampConfidence) {
        self.chunkID = chunkID; self.meetingID = meetingID; self.meetingTitle = meetingTitle
        self.meetingDate = meetingDate; self.speaker = speaker; self.tStart = tStart; self.tEnd = tEnd
        self.source = source; self.alsoInSources = alsoInSources; self.tsConfidence = tsConfidence
    }

    /// Deep link that scrolls the Transcript Viewer to the cited moment.
    public var deepLink: String {
        let t = tStart.map { String(format: "%.2f", $0) } ?? "0"
        return "callbrain://meeting/\(meetingID)?t=\(t)"
    }
}

/// The retrieval unit: a speaker-turn-aware, citation-stable window of utterances.
/// `id` is a stable function of (meetingID, version, seq-range) so re-embeds never break citations.
public struct TranscriptChunk: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let meetingID: String
    public let version: Int
    public let seq: Int
    public var personID: String?
    public var speaker: String
    public var tStart: Double
    public var tEnd: Double
    public var text: String
    public var tokenCount: Int?
    public var explanatoryScore: Double?  // 0–1; up-weights definitional turns for Technical Explainer mode
    public var citation: Citation

    public init(id: String, meetingID: String, version: Int, seq: Int, personID: String? = nil,
                speaker: String, tStart: Double, tEnd: Double, text: String, tokenCount: Int? = nil,
                explanatoryScore: Double? = nil, citation: Citation) {
        self.id = id; self.meetingID = meetingID; self.version = version; self.seq = seq
        self.personID = personID; self.speaker = speaker; self.tStart = tStart; self.tEnd = tEnd
        self.text = text; self.tokenCount = tokenCount; self.explanatoryScore = explanatoryScore
        self.citation = citation
    }
}
