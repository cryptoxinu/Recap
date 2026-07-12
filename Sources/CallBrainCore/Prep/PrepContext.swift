import Foundation

/// Calendar v4 — the deterministic, free (no-LLM) prep context for an upcoming call: what we
/// already know from past calls with the same people/topic. Pure over injected corpus data
/// (like EventMeetingLinker), so it's fully unit-testable and never touches a live Store.
public enum CallPrep {

    /// One past call that's relevant to the upcoming event.
    public struct PriorMeeting: Sendable, Equatable, Identifiable {
        public let meetingID: String
        public let title: String        // displayTitle
        public let date: String         // "YYYY-MM-DD"
        public let oneLiner: String?    // aiSummary
        public let summary: String?     // full callSummary markdown (for the LLM prompt)
        public let openTasks: [String]  // open action-item texts from this call
        public var id: String { meetingID }
        public init(meetingID: String, title: String, date: String, oneLiner: String?,
                    summary: String?, openTasks: [String]) {
            self.meetingID = meetingID; self.title = title; self.date = date
            self.oneLiner = oneLiner; self.summary = summary; self.openTasks = openTasks
        }
    }

    public struct OpenCommitment: Sendable, Equatable {
        public let owner: String?
        public let text: String
        public let meetingDate: String
        public init(owner: String?, text: String, meetingDate: String) {
            self.owner = owner; self.text = text; self.meetingDate = meetingDate
        }
    }

    /// The assembled context. `hasContent` gates the UI: no prior calls → "first call with
    /// these people, nothing to prep from yet" rather than an empty card or a wasted LLM call.
    public struct Context: Sendable, Equatable {
        public let eventTitle: String
        public let start: Date
        public let attendees: [String]
        public let priorMeetings: [PriorMeeting]
        public let recurringTopics: [String]
        public let openCommitments: [OpenCommitment]
        public var hasContent: Bool { !priorMeetings.isEmpty }
        public var meetingIDs: [String] { priorMeetings.map(\.meetingID) }
    }

    /// The corpus slice the assembler reasons over — injected so tests supply fixtures and the
    /// app supplies a Store-backed adapter. A candidate is one past meeting with its people +
    /// open-task texts already gathered.
    public struct Candidate: Sendable, Equatable {
        public let meetingID: String
        public let title: String
        public let date: String          // "YYYY-MM-DD"
        public let oneLiner: String?
        public let summary: String?
        public let people: [String]      // person entities + speakers on that call
        public let openTasks: [(owner: String?, text: String)]
        public let resolvedTasks: [(owner: String?, text: String)]   // done/resolved tasks (cross-call suppression)
        /// Semantic relevance to the upcoming event (0…1), from embedding search over past-call content —
        /// lets a topically-relevant prior call qualify even with a different title + different attendees
        /// (prep FIX 6). nil for lexical-only candidates.
        public let semanticScore: Double?
        public init(meetingID: String, title: String, date: String, oneLiner: String?,
                    summary: String?, people: [String], openTasks: [(owner: String?, text: String)],
                    resolvedTasks: [(owner: String?, text: String)] = [], semanticScore: Double? = nil) {
            self.meetingID = meetingID; self.title = title; self.date = date
            self.oneLiner = oneLiner; self.summary = summary
            self.people = people; self.openTasks = openTasks; self.resolvedTasks = resolvedTasks
            self.semanticScore = semanticScore
        }
        public static func == (l: Candidate, r: Candidate) -> Bool {
            l.meetingID == r.meetingID && l.title == r.title && l.date == r.date
                && l.oneLiner == r.oneLiner && l.summary == r.summary && l.people == r.people
                && l.openTasks.map(\.text) == r.openTasks.map(\.text)
                && l.openTasks.map(\.owner) == r.openTasks.map(\.owner)
                && l.resolvedTasks.map(\.text) == r.resolvedTasks.map(\.text)
        }
    }

    static let maxPriorMeetings = 5
    static let seriesOverlapFloor = 0.5
    /// Conservative floor for the semantic lane (prep FIX 6) — only a clearly on-topic prior call qualifies
    /// on embedding similarity alone, so a loosely-related call isn't dragged into the brief. Public so the
    /// app's gatherer can pre-filter semantic candidates with the SAME threshold.
    public static let semanticFloor = 0.55

    /// Rank candidates by relevance to the upcoming event and assemble the context.
    /// Relevance = title series-match (containment-aware overlap, reusing the linker) OR
    /// attendee first-name overlap. Sorted by (relevance desc, date desc), deduped, capped.
    public static func assemble(eventTitle: String, start: Date, attendees: [String],
                                candidates: [Candidate]) -> Context {
        let eventFirstNames = Set(attendees.compactMap(EventMeetingLinker.firstName))

        let eventTokens = titleTokens(eventTitle)
        struct Ranked { let c: Candidate; let score: Double }
        var ranked: [Ranked] = []
        for c in candidates {
            let titleScore = EventMeetingLinker.titleOverlap(eventTitle, c.title)   // 0…~1
            let candNames = Set(c.people.compactMap(EventMeetingLinker.firstName))
            let sharedPeople = eventFirstNames.intersection(candNames).count
            // Same-series requires the score floor AND real substance: either ≥2 shared
            // meaningful title tokens, OR full containment of the shorter title's meaningful
            // tokens in the longer (so "Morning Sync" ⊆ "Ambient Morning Sync" counts, but a
            // single incidental shared token like "Pricing Chat" vs "Pricing Review" does
            // not — audit LOW), OR attendee support.
            let candTokens = titleTokens(c.title)
            let sharedTokens = eventTokens.intersection(candTokens).count
            let (small, big) = eventTokens.count <= candTokens.count ? (eventTokens, candTokens) : (candTokens, eventTokens)
            let containment = !small.isEmpty && small.isSubset(of: big)
            let qualifiesByTitle = titleScore >= seriesOverlapFloor
                && (sharedTokens >= 2 || containment || sharedPeople >= 1)
            // People-lane gate (prep-audit HIGH: a single shared attendee pulled in unrelated calls).
            // Require a meaningful FRACTION of the event's attendees to overlap, OR ≥2 shared people.
            let peopleFraction = eventFirstNames.isEmpty ? 0 : Double(sharedPeople) / Double(eventFirstNames.count)
            let qualifiesByPeople = sharedPeople >= 2 || (sharedPeople >= 1 && peopleFraction >= 0.34)
            // Semantic lane (prep FIX 6): a strong embedding match to the event's topic qualifies a call
            // even with no shared title tokens or attendees — but at a conservative floor so a merely
            // adjacent call doesn't pull in. Lexical matches still outrank it (its weight is halved).
            let qualifiesBySemantic = (c.semanticScore ?? 0) >= semanticFloor
            guard qualifiesByTitle || qualifiesByPeople || qualifiesBySemantic else { continue }
            let score = (qualifiesByTitle ? titleScore : 0) + Double(sharedPeople) * 0.5
                + (c.semanticScore ?? 0) * 0.5
            ranked.append(Ranked(c: c, score: score))
        }

        ranked.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.c.date != $1.c.date { return $0.c.date > $1.c.date }   // newer first
            return $0.c.meetingID < $1.c.meetingID
        }

        var seen = Set<String>()
        let top = ranked.filter { seen.insert($0.c.meetingID).inserted }.prefix(maxPriorMeetings)

        let priors = top.map { r in
            PriorMeeting(meetingID: r.c.meetingID, title: r.c.title, date: r.c.date,
                         oneLiner: r.c.oneLiner, summary: r.c.summary,
                         openTasks: r.c.openTasks.map(\.text))
        }

        // Tasks marked done/resolved in the chosen calls — used to suppress an "open" commitment that
        // was actually finished in a (usually later) call (prep-audit HIGH: no cross-call resolution).
        // Suppression is OWNER-COMPATIBLE (a done task with a specific owner never cancels a same-text
        // open task owned by a DIFFERENT person) and CHRONOLOGICAL (an open task is only suppressed by a
        // resolution on/after that task's own call, so an older done can't cancel a newer recurrence) —
        // Codex-audit HIGH×2. Exact-text match is deliberately conservative: better to leave a maybe-done
        // task visible than to hide a genuinely-open commitment on a punctuation variance.
        struct Resolution { let ownerFirst: String?; let text: String; let date: String }
        var resolutions: [Resolution] = []
        for r in top {
            for t in r.c.resolvedTasks {
                let text = t.text.trimmingCharacters(in: .whitespaces).lowercased()
                guard !text.isEmpty else { continue }
                resolutions.append(Resolution(ownerFirst: t.owner.flatMap(EventMeetingLinker.firstName),
                                              text: text, date: r.c.date))
            }
        }
        func isResolved(text openText: String, ownerFirst: String?, openedOn openDate: String) -> Bool {
            resolutions.contains { rt in
                rt.text == openText && rt.date >= openDate
                    && (rt.ownerFirst == nil || ownerFirst == nil || rt.ownerFirst == ownerFirst)
            }
        }

        // Open commitments across the chosen calls, newest call first, deduped by (owner, text).
        var commitments: [OpenCommitment] = []
        var seenPair = Set<String>()
        for r in top {
            // A commitment OWNER must be credibly a participant of THIS call — an ungrounded/garbled
            // owner is shown UNATTRIBUTED, never as an authoritative "X owes Y" (prep-audit HIGH). But if
            // the call yielded NO extracted people at all we have nothing to ground against, so we keep the
            // raw owner rather than nuking every attribution (Codex-audit: don't over-null on empty sets).
            let callFirstNames = Set(r.c.people.compactMap(EventMeetingLinker.firstName))
            for t in r.c.openTasks {
                let text = t.text.trimmingCharacters(in: .whitespaces)
                let ownerFirst = t.owner.flatMap(EventMeetingLinker.firstName)
                guard !text.isEmpty,
                      !isResolved(text: text.lowercased(), ownerFirst: ownerFirst, openedOn: r.c.date)
                else { continue }
                let owner: String? = {
                    guard let o = t.owner, let of = EventMeetingLinker.firstName(o) else { return nil }
                    if callFirstNames.isEmpty { return o }            // nothing to ground against → keep
                    return callFirstNames.contains(of) ? o : nil      // grounded participant → keep, else drop
                }()
                let key = (owner?.lowercased() ?? "") + "\u{1}" + text.lowercased()
                guard seenPair.insert(key).inserted else { continue }
                commitments.append(OpenCommitment(owner: owner, text: text, meetingDate: r.c.date))
            }
        }

        // Recurring topics from call CONTENT (the one-liner summaries) rather than title words — so a
        // normally-named "Weekly Sync" series surfaces what's actually discussed, not the series name
        // ("Morning") or nothing at all (prep-audit HIGH).
        let topics = recurringContentTopics(top.map { $0.c.oneLiner })

        return Context(eventTitle: eventTitle, start: start, attendees: attendees,
                       priorMeetings: Array(priors), recurringTopics: topics,
                       openCommitments: commitments)
    }

    /// Meaningful lowercased title tokens (>2 chars, stopword-light) — the shared vocabulary
    /// used for series matching and recurring topics.
    static func titleTokens(_ title: String) -> Set<String> {
        Set(title.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 && !EventMeetingLinker.titleStopwords.contains($0) })
    }

    /// Recurring SUBJECTS across the chosen calls' one-liner summaries — the topics that actually
    /// repeat (content), not the meeting's title words. A token counts once per summary (so one gushing
    /// summary can't fake a recurrence); kept when it appears in ≥2 calls; ranked by frequency.
    static func recurringContentTopics(_ oneLiners: [String?], limit: Int = 4) -> [String] {
        let texts = oneLiners.compactMap { $0 }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard texts.count >= 2 else { return [] }
        var counts: [String: Int] = [:]; var display: [String: String] = [:]
        for t in texts {
            for tok in titleTokens(t) {   // titleTokens is a Set → already once-per-summary
                counts[tok, default: 0] += 1
                if display[tok] == nil { display[tok] = tok.prefix(1).uppercased() + tok.dropFirst() }
            }
        }
        return counts.filter { $0.value >= 2 }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(limit).compactMap { display[$0.key] }
    }

    static func recurringTitleTopics(_ titles: [String]) -> [String] {
        guard titles.count >= 2 else { return [] }
        var counts: [String: Int] = [:]
        var display: [String: String] = [:]
        for t in titles {
            for tok in titleTokens(t) {
                counts[tok, default: 0] += 1
                if display[tok] == nil { display[tok] = tok.prefix(1).uppercased() + tok.dropFirst() }
            }
        }
        return counts.filter { $0.value >= 2 }.keys.sorted().compactMap { display[$0] }
    }
}
