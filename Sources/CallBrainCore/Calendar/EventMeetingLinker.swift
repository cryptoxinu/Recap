import Foundation

/// Calendar initiative C1 — the normalized calendar event. Source-agnostic: EventKit and the
/// direct Google source both map into this, so the linker and UI never know the provider.
public struct CalendarEvent: Sendable, Equatable, Identifiable {
    public enum SourceKind: String, Sendable, Codable { case eventKit, google }
    public let stableID: String        // provider's stable identifier
    public let sourceKind: SourceKind
    public let calendarName: String    // "Work", "you@…"
    public let title: String
    public let start: Date
    public let end: Date
    public let attendees: [String]     // display names only
    /// Attendee email addresses when the provider exposes them (EventKit mailto URLs / Google
    /// `email`). Additive — the linker never reads these; used only by attendee research to
    /// resolve external people to their company by email domain. Parallel to (not aligned with)
    /// `attendees`, since a name may lack an email and vice-versa.
    public let attendeeEmails: [String]
    public let isAllDay: Bool
    /// The source calendar's display color as "#RRGGBB" (chips render in calendar colors).
    public let colorHex: String?
    /// v3 detail-panel richness (additive — the linker never reads these).
    public let location: String?
    public let notes: String?
    public let url: String?
    /// True when the event's calendar can't be modified (holidays, birthdays, subscribed
    /// feeds, or any directly-connected Google calendar) — the UI hides Edit/drag (v4 write).
    public let isReadOnly: Bool
    /// The owning calendar's stable identifier (EventKit) — so an edit writes back to the
    /// EXACT calendar even when two accounts share a display name (v4 write audit HIGH).
    public let calendarID: String?
    public var id: String { "\(sourceKind.rawValue)|\(stableID)" }

    public init(stableID: String, sourceKind: SourceKind, calendarName: String, title: String,
                start: Date, end: Date, attendees: [String], attendeeEmails: [String] = [],
                isAllDay: Bool, colorHex: String? = nil,
                location: String? = nil, notes: String? = nil, url: String? = nil,
                isReadOnly: Bool = false, calendarID: String? = nil) {
        self.stableID = stableID; self.sourceKind = sourceKind; self.calendarName = calendarName
        self.title = title; self.start = start; self.end = end
        self.attendees = attendees; self.attendeeEmails = attendeeEmails; self.isAllDay = isAllDay
        self.colorHex = colorHex
        self.location = location; self.notes = notes; self.url = url
        self.isReadOnly = isReadOnly; self.calendarID = calendarID
    }
}

/// The pure event↔meeting matcher. Signals: same LOCAL day (hard gate) · start-time proximity ·
/// normalized title-token overlap · attendee↔people overlap. Conservative like
/// CrossSourceLinker: a link needs BOTH enough score and a clear margin over the runner-up —
/// ambiguity means no link (a wrong link misleads worse than no link).
public enum EventMeetingLinker {

    public struct MeetingCandidate: Sendable, Equatable {
        public let meetingID: String
        public let title: String       // displayTitle (AI title when present)
        public let date: String        // YMD (meetings.date)
        public let startedAt: Date?    // meetings.start_time when known
        public let people: [String]    // person entities + known speakers
        public init(meetingID: String, title: String, date: String, startedAt: Date?, people: [String]) {
            self.meetingID = meetingID; self.title = title; self.date = date
            self.startedAt = startedAt; self.people = people
        }
    }

    public struct Link: Sendable, Equatable {
        public let eventID: String     // CalendarEvent.id (source-qualified)
        public let meetingID: String
        public let confidence: Double  // 0-1
        public let method: String      // "time+title", "attendees", "recording", …
        // Snapshot for rendering without re-querying the provider:
        public let eventTitle: String
        public let eventStart: Date
        public init(eventID: String, meetingID: String, confidence: Double, method: String,
                    eventTitle: String, eventStart: Date) {
            self.eventID = eventID; self.meetingID = meetingID; self.confidence = confidence
            self.method = method; self.eventTitle = eventTitle; self.eventStart = eventStart
        }
    }

    static let linkThreshold = 0.55
    static let ambiguityMargin = 0.15

    /// The timed event happening at `now` (grace on each side so a call joined a few minutes early/late
    /// still matches), best-overlap first. Pure — used to auto-link a manual recording to the scheduled
    /// call the founder is on. nil when nothing overlaps.
    public static func happeningNow(_ events: [CalendarEvent], now: Date, grace: TimeInterval = 5 * 60) -> CalendarEvent? {
        let candidates = events.filter { !$0.isAllDay
            && $0.start.addingTimeInterval(-grace) <= now
            && now <= $0.end.addingTimeInterval(grace) }
        func inProgress(_ e: CalendarEvent) -> Bool { e.start <= now && now <= e.end }
        // An event actually IN PROGRESS beats one only inside the pre/post-start grace (audit HIGH: at
        // 10:52 the ongoing 10:00–11:00 call must win over a 10:55 call). Among the same class, the one
        // whose start is nearest now wins.
        return candidates.min { a, b in
            let ai = inProgress(a), bi = inProgress(b)
            if ai != bi { return ai }
            return abs(a.start.timeIntervalSince(now)) < abs(b.start.timeIntervalSince(now))
        }
    }

    public static func links(events: [CalendarEvent], meetings: [MeetingCandidate],
                             calendar: Calendar = .current) -> [Link] {
        // Score every same-day pair.
        struct Scored { let event: CalendarEvent; let meeting: MeetingCandidate
                        let score: Double; let method: String }
        var scored: [Scored] = []
        for e in events where !e.isAllDay {
            let eventYMD = TimeCode.ymd(e.start, calendar: calendar)
            for m in meetings where m.date == eventYMD {
                let (s, method) = score(event: e, meeting: m)
                if s > 0 { scored.append(Scored(event: e, meeting: m, score: s, method: method)) }
            }
        }
        // Greedy best-first one-to-one assignment with an ambiguity check per pick: if the
        // runner-up FOR THE SAME EVENT or SAME MEETING is within the margin, skip both — a
        // human should not be silently guessed for.
        scored.sort { $0.score > $1.score }
        var usedEvents = Set<String>(), usedMeetings = Set<String>()
        var out: [Link] = []
        for s in scored {
            guard s.score >= linkThreshold,
                  !usedEvents.contains(s.event.id), !usedMeetings.contains(s.meeting.meetingID) else { continue }
            let rival = scored.first {
                ($0.event.id == s.event.id || $0.meeting.meetingID == s.meeting.meetingID)
                    && !($0.event.id == s.event.id && $0.meeting.meetingID == s.meeting.meetingID)
                    && !usedEvents.contains($0.event.id) && !usedMeetings.contains($0.meeting.meetingID)
            }
            if let rival, s.score - rival.score < ambiguityMargin {
                // Ambiguous: consume only the CONTESTED side, so an unambiguous third pairing
                // on the other side stays linkable (gate MED — consuming both blocked it).
                if rival.event.id == s.event.id { usedEvents.insert(s.event.id) }
                if rival.meeting.meetingID == s.meeting.meetingID { usedMeetings.insert(s.meeting.meetingID) }
                continue
            }
            usedEvents.insert(s.event.id); usedMeetings.insert(s.meeting.meetingID)
            out.append(Link(eventID: s.event.id, meetingID: s.meeting.meetingID,
                            confidence: min(1, s.score), method: s.method,
                            eventTitle: s.event.title, eventStart: s.event.start))
        }
        return out
    }

    /// Score one same-day pair. Components sum; the day gate already passed.
    static func score(event e: CalendarEvent, meeting m: MeetingCandidate) -> (Double, String) {
        var s = 0.0
        var methods: [String] = []

        // Start-time proximity (strongest signal when both sides have one).
        if let started = m.startedAt {
            let delta = abs(e.start.timeIntervalSince(started))
            if delta <= 10 * 60 { s += 0.55; methods.append("time") }
            else if delta <= 30 * 60 { s += 0.35; methods.append("time~") }
            else if delta > 3 * 3600 { s -= 0.4 }   // hours apart on the same day → penalize
        }

        // Title-token overlap (stopword-light Jaccard over meaningful tokens).
        let overlap = titleOverlap(e.title, m.title)
        if overlap >= 0.8 { s += 0.6; methods.append("title") }   // near-exact title alone clears
        else if overlap >= 0.4 { s += 0.3; methods.append("title~") }

        // Attendee↔people overlap by first-name fold.
        let eNames = Set(e.attendees.compactMap(firstName))
        let mNames = Set(m.people.compactMap(firstName))
        let shared = eNames.intersection(mNames).count
        if shared >= 2 { s += 0.4; methods.append("attendees") }
        else if shared == 1 { s += 0.15 }

        return (s, methods.isEmpty ? "day" : methods.joined(separator: "+"))
    }

    static func firstName(_ full: String) -> String? {
        let f = full.split(separator: " ").first.map(String.init)?.lowercased()
        return (f?.count ?? 0) >= 2 ? f : nil
    }

    static let titleStopwords: Set<String> = ["the", "a", "an", "and", "with", "for", "of",
                                              "meeting", "call", "sync", "recording", "weekly",
                                              "daily", "notes"]

    /// Public title-similarity (0…~1) — the containment-aware overlap, exposed so the app's
    /// prep-gathering can pre-filter candidate meetings by series match.
    public static func titleSimilarity(_ a: String, _ b: String) -> Double { titleOverlap(a, b) }

    static func titleOverlap(_ a: String, _ b: String) -> Double {
        func tokens(_ s: String, keepStopwords: Bool) -> Set<String> {
            Set(s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count > 1 && (keepStopwords || !titleStopwords.contains($0)) })
        }
        // Full containment of one title's RAW tokens inside the other's (≥2 tokens) is
        // near-exact — founder's real case: the calendar says "morning sync", the import
        // says "Ambient Morning Sync", and "sync" is a stopword so Jaccard alone scored
        // 0.5. Stopwords are KEPT for the subset test (load-bearing when half the name), BUT
        // the shorter title must carry ≥1 MEANINGFUL token — else "weekly sync" ⊆ "Ambient
        // Weekly Sync" would auto-link on pure stopwords (v3-latecommits audit HIGH).
        let rawA = tokens(a, keepStopwords: true), rawB = tokens(b, keepStopwords: true)
        let (shorter, longer) = rawA.count <= rawB.count ? (rawA, rawB) : (rawB, rawA)
        let shorterMeaningful = shorter.subtracting(titleStopwords)
        let contained = shorter.count >= 2 && shorter.isSubset(of: longer) && !shorterMeaningful.isEmpty

        let ta = tokens(a, keepStopwords: false), tb = tokens(b, keepStopwords: false)
        guard !ta.isEmpty, !tb.isEmpty else { return contained ? 0.85 : 0 }
        let jaccard = Double(ta.intersection(tb).count) / Double(ta.union(tb).count)
        return contained ? max(jaccard, 0.85) : jaccard
    }
}
