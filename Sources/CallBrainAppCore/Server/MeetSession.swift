import Foundation

/// One finalized/stable Google Meet caption turn.
///
/// Speaker names come from Meet captions and can be real participant names. The type is intentionally
/// a small immutable value so snapshots can safely cross concurrency domains.
public struct CaptionTurn: Sendable, Equatable, Codable {
    public let speaker: String
    public let text: String

    public init(speaker: String, text: String) {
        self.speaker = speaker
        self.text = text
    }
}

/// Thread-safe, bounded accumulator for the current Google Meet caption transcript.
///
/// Meet often re-emits the same caption block as it grows or mutates. When a new turn has the same
/// speaker as the retained tail and either side is a prefix of the other, the tail is replaced by
/// the longer text instead of appending a duplicate. Storage is capped to the most recent turns so a
/// long meeting cannot grow memory without bound.
public final class MeetSession: @unchecked Sendable {
    private static let maxSpeakerCharacters = 120
    private static let maxTextCharacters = 4_000
    private static let transcriptSeparatorBytes = 1
    private static let speakerSeparatorBytes = 2

    private let lock = NSLock()
    private let maxTurns: Int
    private let maxTotalBytes: Int
    private var retained: [CaptionTurn] = []
    private var retainedBytes = 0
    private var lastTurnFinal = true   // was the newest retained turn a finalized caption?
    private var recordingLeased = false   // a live recording owns this buffer (see beginRecording)
    private var droppedWhileLeased = false // did the cap evict any turn during the current recording lease?

    public init(maxTurns: Int = 2_000, maxTotalBytes: Int = 512 * 1_024) {
        self.maxTurns = max(1, maxTurns)
        self.maxTotalBytes = max(1, maxTotalBytes)
    }

    /// Append a speaker-labeled caption turn, trimming input and ignoring empty values.
    ///
    /// `final == false` marks a live (still-updating) Meet caption for the current utterance. While the
    /// last retained turn is still provisional and from the same speaker, an incoming update REPLACES it
    /// (Meet revises the active caption in place — including non-prefix ASR corrections) instead of
    /// appending a duplicate. Once a turn is finalized (`final == true`), the next same-speaker turn is a
    /// new utterance and appends. This fixes the caption duplication/bloat on real calls (audit MED).
    public func append(speaker: String, text: String, final: Bool = true) {
        let trimmedSpeaker = Self.truncated(
            speaker.trimmingCharacters(in: .whitespacesAndNewlines),
            maxCharacters: Self.maxSpeakerCharacters
        )
        let trimmedText = Self.truncated(
            text.trimmingCharacters(in: .whitespacesAndNewlines),
            maxCharacters: Self.maxTextCharacters
        )
        guard !trimmedSpeaker.isEmpty, !trimmedText.isEmpty else { return }

        let incoming = CaptionTurn(speaker: trimmedSpeaker, text: trimmedText)
        lock.withLock {
            defer { lastTurnFinal = final }
            guard let last = retained.last else {
                applyCapped([incoming])
                return
            }

            let sameSpeaker = last.speaker == incoming.speaker
            if sameSpeaker && (!lastTurnFinal || Self.shouldReplaceTail(last: last, incoming: incoming)) {
                // Provisional revision → newest wins; prefix growth on a finalized turn → keep the longer.
                let replacement = lastTurnFinal
                    ? (incoming.text.count >= last.text.count ? incoming : last)
                    : incoming
                applyCapped(Array(retained.dropLast()) + [replacement])
                return
            }

            applyCapped(retained + [incoming])
        }
    }

    /// Cap `candidate` and commit it as the retained buffer. MUST be called while holding `lock`. If the cap
    /// EVICTS any turn while a recording holds the lease, records that the recording's transcript was
    /// truncated (T2 audit MED) — the caller then falls back to WhisperKit over the full WAV rather than
    /// silently saving a head-truncated caption transcript.
    private func applyCapped(_ candidate: [CaptionTurn]) {
        let capped = Self.capped(candidate, maxTurns: maxTurns, maxTotalBytes: maxTotalBytes)
        if recordingLeased && capped.turns.count < candidate.count { droppedWhileLeased = true }
        retained = capped.turns
        retainedBytes = capped.bytes
    }

    /// Speaker-labeled transcript with the oldest retained turn first and newest last.
    public func transcript() -> String {
        lock.withLock {
            retained.map { "\($0.speaker): \($0.text)" }.joined(separator: "\n")
        }
    }

    /// Snapshot of the retained caption turns (oldest→newest) — the STRUCTURED form the recording path
    /// persists as a sidecar so the import pipeline can ingest real named turns (T2), not re-parse text.
    public func turns() -> [CaptionTurn] {
        lock.withLock { retained }
    }

    /// Clear all retained turns, usually after a successful final import.
    public func reset() {
        lock.withLock {
            retained = []
            retainedBytes = 0
            lastTurnFinal = true
        }
    }

    /// Reset that RESPECTS an active recording lease (audit HIGH): the extension `/import` path calls this
    /// so a mid-recording import can never wipe the captions a live recording is still accumulating. A
    /// no-op while a recording holds the lease; a normal reset otherwise.
    public func resetUnlessRecording() {
        lock.withLock {
            guard !recordingLeased else { return }
            retained = []
            retainedBytes = 0
            lastTurnFinal = true
        }
    }

    /// A live recording claims this caption buffer: clear any prior captions AND take the lease, all under
    /// ONE lock — so early captions relayed during the (awaited) audio-capture startup aren't lost to a
    /// separate reset, and a concurrent `/import` can't clear the buffer mid-recording (audit HIGH/MED).
    public func beginRecording() {
        lock.withLock {
            retained = []
            retainedBytes = 0
            lastTurnFinal = true
            recordingLeased = true
            droppedWhileLeased = false
        }
    }

    /// One recording's harvested captions plus whether the live buffer's cap evicted any turn during the
    /// recording (`truncated` → the saved transcript would be head-truncated, so the caller should prefer
    /// WhisperKit over the full WAV instead).
    public struct RecordingHarvest: Sendable, Equatable {
        public let turns: [CaptionTurn]
        public let truncated: Bool
    }

    /// End a recording's caption window: atomically SNAPSHOT the captured turns, report whether the cap
    /// truncated them, clear the buffer, and drop the lease — one lock, so a concurrent `/live` append
    /// can't be dropped-then-erased or leak into the next recording (audit HIGH). Safe on any stop path.
    @discardableResult
    public func endRecording() -> RecordingHarvest {
        lock.withLock {
            let out = RecordingHarvest(turns: retained, truncated: droppedWhileLeased)
            retained = []
            retainedBytes = 0
            lastTurnFinal = true
            recordingLeased = false
            droppedWhileLeased = false
            return out
        }
    }

    public var isEmpty: Bool {
        lock.withLock { retained.isEmpty }
    }

    /// Whether a live recording currently holds the caption buffer.
    public var isRecordingLeased: Bool {
        lock.withLock { recordingLeased }
    }

    private static func shouldReplaceTail(last: CaptionTurn, incoming: CaptionTurn) -> Bool {
        guard last.speaker == incoming.speaker else { return false }
        return incoming.text == last.text
            || incoming.text.hasPrefix(last.text)
            || last.text.hasPrefix(incoming.text)
    }

    private static func capped(_ turns: [CaptionTurn], maxTurns: Int,
                               maxTotalBytes: Int) -> (turns: [CaptionTurn], bytes: Int) {
        var cappedTurns = turns.count > maxTurns ? Array(turns.suffix(maxTurns)) : turns
        var bytes = transcriptBytes(cappedTurns)
        while bytes > maxTotalBytes, !cappedTurns.isEmpty {
            cappedTurns = Array(cappedTurns.dropFirst())
            bytes = transcriptBytes(cappedTurns)
        }
        return (cappedTurns, bytes)
    }

    private static func transcriptBytes(_ turns: [CaptionTurn]) -> Int {
        guard !turns.isEmpty else { return 0 }
        let lineBytes = turns.reduce(0) { total, turn in
            total + turn.speaker.utf8.count + speakerSeparatorBytes + turn.text.utf8.count
        }
        return lineBytes + max(0, turns.count - 1) * transcriptSeparatorBytes
    }

    private static func truncated(_ value: String, maxCharacters: Int) -> String {
        guard value.count > maxCharacters else { return value }
        return String(value.prefix(maxCharacters))
    }
}
