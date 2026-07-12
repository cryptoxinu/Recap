import Foundation

// MARK: - Parser output (pre-ingest)
//
// Parsers are pure + deterministic: bytes/text in → ParsedTranscript out. They do NOT
// assign final UUIDv7 ids, resolve people, or touch the store — that is the ingest layer.
// See docs/ARCHITECTURE.md §6.

/// One speaker turn straight out of a parser (final ids/personID assigned later by ingest).
public struct ParsedUtterance: Codable, Sendable, Equatable {
    public let seq: Int
    public var speakerRaw: String
    public var speakerConfidence: Double?
    public var tStart: Double
    public var tEnd: Double
    public var text: String
    public var isInferredSpeaker: Bool
    public var tsConfidence: TimestampConfidence

    public init(seq: Int, speakerRaw: String, speakerConfidence: Double? = nil,
                tStart: Double, tEnd: Double, text: String,
                isInferredSpeaker: Bool = false, tsConfidence: TimestampConfidence = .exact) {
        self.seq = seq; self.speakerRaw = speakerRaw; self.speakerConfidence = speakerConfidence
        self.tStart = tStart; self.tEnd = tEnd; self.text = text
        self.isInferredSpeaker = isInferredSpeaker; self.tsConfidence = tsConfidence
    }
}

/// A source transcript normalized into the CTM shape. `title`/`date` are optional because some
/// sources (e.g. a Fathom copy) don't carry them — the ingest layer fills them from filename/mtime.
public struct ParsedTranscript: Codable, Sendable, Equatable {
    public var title: String?
    public var date: String?              // "YYYY-MM-DD"
    public var startedAt: Date?
    public var durationSeconds: Int?
    public var source: MeetingSource
    public var speakers: [String]         // distinct raw labels, first-seen order
    public var utterances: [ParsedUtterance]

    public init(title: String? = nil, date: String? = nil, startedAt: Date? = nil,
                durationSeconds: Int? = nil, source: MeetingSource,
                speakers: [String] = [], utterances: [ParsedUtterance]) {
        self.title = title; self.date = date; self.startedAt = startedAt
        self.durationSeconds = durationSeconds; self.source = source
        self.speakers = speakers; self.utterances = utterances
    }
}

public enum ParseError: Error, Sendable, Equatable {
    case empty
    case unrecognizedStructure(String)
    case decoding(String)
}

/// Shared timecode parsing: "H:MM:SS", "MM:SS", or "M:SS" → seconds. Returns nil if not a timecode.
public enum TimeCode {
    public static func seconds(from s: String) -> Double? {
        let parts = s.split(separator: ":").map(String.init)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        let nums = parts.compactMap { Int($0) }
        guard nums.count == parts.count else { return nil }
        if nums.count == 2 { return Double(nums[0] * 60 + nums[1]) }
        return Double(nums[0] * 3600 + nums[1] * 60 + nums[2])
    }

    /// "YYYY-MM-DD" for a Date in the current calendar/timezone.
    public static func ymd(_ d: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Seconds → "MM:SS" (or "H:MM:SS" past an hour) — the inverse of `seconds(from:)`, for
    /// timestamped evidence lines and citation chips (perfection plan Task 1.2).
    public static func mmss(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}
