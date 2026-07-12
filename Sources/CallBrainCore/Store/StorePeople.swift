import Foundation
import GRDB

/// Perfection plan Task 8.2 — the People read path. Aggregates person entities across the
/// archive with a junk filter (on-device NER emits tokens like "Bundling"/"Merkel" — audit):
/// a name must either span ≥2 meetings or contain a space (first+last) to count as a person.
extension Store {

    /// Product/tool names the on-device NER keeps tagging as PEOPLE ("Gemini said…") — never
    /// people pages or profile suggestions. Lowercased.
    public static let knownNonPeople: Set<String> = [
        "gemini", "fathom", "fireflies", "claude", "codex", "chatgpt", "gpt", "copilot",
        "zoom", "siri", "alexa", "ollama", "whisper", "cursor", "ambient",
    ]

    public struct PersonSummary: Sendable, Equatable, Identifiable {
        public let name: String
        public let meetingCount: Int
        public let mentions: Int
        public let lastSeen: String    // YMD of the newest meeting they appear in
        public var id: String { name }
    }

    public struct PersonDetail: Sendable {
        public let meetings: [MeetingRow]
        public let openTasks: [TaskRow]
    }

    /// The People roster. The old query trusted RAW NLTagger person tags (keep anything with a space OR
    /// ≥2 meetings, minus a 15-word blocklist), which flooded the list with non-people — acronyms (AI/UI/
    /// API/CUDA), AI/crypto product & model names (Ambient/Solana/Kimi/Moonshot/Gemma), generic "Speaker N"
    /// labels, and one real person fragmented across spellings (audit: founder "pulling in random things
    /// that aren't even people"). This GROUNDS the roster on real people using several signals:
    ///   1. drop generic speaker labels + acronyms + tool/tech/product names (EntityExtractor read-path
    ///      plausibility) + names that are org-dominant in the corpus (products NLTagger also tags as orgs);
    ///   2. admit a candidate only if it is GROUNDED — matches a real named (non-generic) diarized speaker
    ///      by exact or first-name compatibility — OR recurs across ≥2 meetings as a plausible person name;
    ///   3. de-fragment display names ("Alex"/"Alexander Chen", "Robin"/"Robin", Whisper-mangled surnames)
    ///      with the shared `OwnerResolver` (the same engine Tasks uses), re-aggregating distinct-meeting
    ///      counts correctly.
    /// `excluding` (lowercased, ALWAYS-exclude) = the founder's own aliases + venture NAMES — kept out of
    /// Store so no personal names are hardcoded here. `excludingUngrounded` (lowercased) = venture KEYWORDS,
    /// which are product/domain terms (e.g. an AI product literally named "Pearl") and should be dropped —
    /// but ONLY for non-grounded names, so a real diarized SPEAKER who happens to collide with a keyword
    /// still survives (a keyword can occasionally also be a real person's name).
    /// `blocklist` (lowercased, EXACT display-name match) = names the user has right-clicked → "Not a person"
    /// — a user-taught override for the ambiguous cases the automatic filter can't resolve. Checked against
    /// the final de-fragmented display name, so dismissing "Kimmy K2.7" doesn't also remove the person "Kimmy".
    public func people(limit: Int = 100, excluding: Set<String> = [],
                       excludingUngrounded: Set<String> = [], blocklist: Set<String> = []) throws -> [PersonSummary] {
        try dbQueue.read { db in
            // 1) Grounding truth: real, named (non-generic) diarized speakers across the whole corpus.
            // Read from transcript_chunks.speaker (indexed by ix_chunks_speaker) rather than utterances
            // (whose speaker column is unindexed) so this stays cheap on a large archive (audit perf).
            var trusted = Set<String>()
            for s in try String.fetchAll(db, sql:
                "SELECT DISTINCT speaker FROM transcript_chunks WHERE speaker IS NOT NULL AND speaker <> ''") {
                guard !SpeakerResolver.isGeneric(s) else { continue }
                let n = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                // "Speaker 1" isn't `isGeneric` (deliberate elsewhere) but is never a person here.
                guard !n.isEmpty, n.range(of: #"^speaker\s*\d+$"#, options: .regularExpression) == nil,
                      !Self.knownNonPeople.contains(n), n != "gemini notes", n != "unknown" else { continue }
                trusted.insert(n)
            }
            let trustedFirst = Set(trusted.map { $0.split(separator: " ").first.map(String.init) ?? $0 })

            // 2) Names NLTagger also tags as organizations (products/companies) → drop when org-dominant.
            var orgMeetings: [String: Int] = [:]
            for r in try Row.fetchAll(db, sql:
                "SELECT name_lower AS nl, COUNT(DISTINCT meeting_id) AS c FROM meeting_entities WHERE kind = 'organization' GROUP BY name_lower") {
                orgMeetings[r["nl"]] = r["c"]
            }

            // 3) Aggregate every person entity by name (distinct meetings, mentions, newest date).
            struct Agg { var name: String; var meetings: Set<String>; var mentions: Int; var lastSeen: String; var best: Int }
            var byName: [String: Agg] = [:]
            for r in try Row.fetchAll(db, sql: """
                SELECT e.name_lower AS nl, e.name AS name, e.meeting_id AS mid, e.count AS cnt, m.date AS date
                FROM meeting_entities e JOIN meetings m ON m.id = e.meeting_id
                WHERE e.kind = 'person'
                """) {
                let nl: String = r["nl"], name: String = r["name"], mid: String = r["mid"]
                let cnt: Int = r["cnt"], date: String = r["date"]
                if var a = byName[nl] {
                    a.meetings.insert(mid); a.mentions += cnt
                    if date > a.lastSeen { a.lastSeen = date }
                    if cnt > a.best { a.best = cnt; a.name = name }
                    byName[nl] = a
                } else {
                    byName[nl] = Agg(name: name, meetings: [mid], mentions: cnt, lastSeen: date, best: cnt)
                }
            }

            // 4) Admit only real people.
            func grounded(_ nl: String) -> Bool {
                if trusted.contains(nl) { return true }
                let first = nl.split(separator: " ").first.map(String.init) ?? nl
                return trustedFirst.contains(first)
            }
            // Token-aware match: entities are full name_lowers ("zach kalarikkal") while the exclude sets hold
            // first-name aliases / venture terms, so match if the WHOLE name OR any of its tokens is in the set
            // (audit: exact Set.contains left the founder in their own roster when their alias was a bare name).
            func tokenMatch(_ nl: String, _ set: Set<String>) -> Bool {
                if set.isEmpty { return false }
                if set.contains(nl) { return true }
                return nl.split(separator: " ").contains { set.contains(String($0)) }
            }
            var admitted: [Agg] = []
            for (nl, a) in byName {
                guard nl.range(of: #"^speaker\s*\d+$"#, options: .regularExpression) == nil else { continue }
                let isGrounded = grounded(nl)
                // ALWAYS exclude the user + venture names; exclude venture KEYWORDS only for NON-grounded names
                // (a product keyword like "pearl" is dropped, but a real speaker who matches a keyword stays).
                if tokenMatch(nl, excluding) { continue }
                if !isGrounded, tokenMatch(nl, excludingUngrounded) { continue }
                guard EntityExtractor.isLikelyPersonName(a.name), !EntityExtractor.isAcronym(a.name) else { continue }
                // Org-dominance drop applies ONLY to non-grounded names, and STRICT > — so a real diarized
                // speaker mis-tagged as an org (NLTagger's surname/org bias: "Morgan", "Chase") is never
                // deleted, and an even person/org split keeps the person (audit).
                if !isGrounded, let oc = orgMeetings[nl], oc > a.meetings.count { continue }
                guard isGrounded || a.meetings.count >= 2 else { continue }
                admitted.append(a)
            }

            // 5) De-fragment display names with the shared OwnerResolver, re-aggregating by canonical name.
            let counts = Dictionary(admitted.map { ($0.name, $0.mentions) }, uniquingKeysWith: +)
            let canon = OwnerResolver.canonicalMap(ownerCounts: counts)
            var merged: [String: Agg] = [:]
            for a in admitted {
                let display = canon[a.name] ?? a.name
                let key = display.lowercased()
                if tokenMatch(key, excluding) { continue }   // a variant may canonicalize onto an excluded name
                if var m = merged[key] {
                    m.meetings.formUnion(a.meetings); m.mentions += a.mentions
                    if a.lastSeen > m.lastSeen { m.lastSeen = a.lastSeen }
                    merged[key] = m
                } else {
                    merged[key] = Agg(name: display, meetings: a.meetings, mentions: a.mentions,
                                      lastSeen: a.lastSeen, best: a.best)
                }
            }

            // Broken into explicit steps (the chained filter/map/sort/prefix tripped the Swift
            // type-checker's "unable to type-check in reasonable time" on one expression).
            let summaries: [PersonSummary] = merged.values.compactMap { a in
                let low = a.name.lowercased()
                if Self.knownNonPeople.contains(low) || blocklist.contains(low) { return nil }
                return PersonSummary(name: a.name, meetingCount: a.meetings.count,
                                     mentions: a.mentions, lastSeen: a.lastSeen)
            }
            let ranked = summaries.sorted { l, r in
                if l.meetingCount != r.meetingCount { return l.meetingCount > r.meetingCount }
                if l.mentions != r.mentions { return l.mentions > r.mentions }
                return l.name < r.name
            }
            return Array(ranked.prefix(limit))
        }
    }

    /// Apply a confirmed speaker name across ONE meeting (Task 8.1): utterances + chunks in a
    /// single transaction; the chunk_id-keyed FTS triggers keep search in sync.
    public func renameSpeaker(meetingID: String, from: String, to: String) throws -> (utterances: Int, chunks: Int) {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE utterances SET speaker = ? WHERE meeting_id = ? AND speaker = ?",
                           arguments: [to, meetingID, from])
            let u = db.changesCount
            try db.execute(sql: "UPDATE transcript_chunks SET speaker = ? WHERE meeting_id = ? AND speaker = ?",
                           arguments: [to, meetingID, from])
            return (u, db.changesCount)
        }
    }

    /// One-time summaries-v2 migration helper: clear LOCAL-model summaries (the pre-v2 mush)
    /// so the standard backfill regenerates them through the fact pipeline. Gemini notes and
    /// cloud (Opus) summaries are untouched.
    @discardableResult
    public func clearLocalSummaries() throws -> Int {
        try dbQueue.write { db in
            try db.execute(sql: """
                UPDATE meetings SET call_summary = NULL, summary_source = NULL
                WHERE summary_source = 'local'
                """)
            return db.changesCount
        }
    }

    /// Entities of the given kinds spanning ≥`minMeetings` meetings (profile enrichment, 8.6).
    public func recurringEntities(kinds: [String], minMeetings: Int) throws -> [(name: String, meetingCount: Int)] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT MAX(name) AS name, COUNT(DISTINCT meeting_id) AS mc FROM meeting_entities
                WHERE kind IN (SELECT value FROM json_each(?))
                GROUP BY name_lower HAVING mc >= ?
                ORDER BY mc DESC
                """, arguments: [Self.jsonArray(kinds), minMeetings])
                .filter { !Self.knownNonPeople.contains(($0["name"] as String).lowercased()) }
                .map { ($0["name"], $0["mc"]) }
        }
    }

    /// A person's meetings (newest first) + open tasks they own. Matches by name PREFIX both
    /// ways ("Riley" matches "Riley Novak" and vice versa) since NER and task owners disagree
    /// on full vs first names.
    public func personDetail(name: String) throws -> PersonDetail {
        // Word-boundary matching (gate MED: 'Alex' must not swallow 'Alexander'): exact first name,
        // exact full name, or first name followed by a SPACE.
        let first = name.split(separator: " ").first.map(String.init) ?? name
        let like = "\(first) %"
        return try dbQueue.read { db in
            let meetings = try Row.fetchAll(db, sql: """
                SELECT \(Self.meetingCols) FROM meetings WHERE id IN (
                  SELECT DISTINCT meeting_id FROM meeting_entities
                  WHERE kind = 'person' AND (name = ? COLLATE NOCASE OR name = ? COLLATE NOCASE
                                             OR name LIKE ? COLLATE NOCASE))
                ORDER BY date DESC, created_at DESC
                """, arguments: [name, first, like]).map(MeetingRow.from)
            let tasks = try Row.fetchAll(db, sql: """
                SELECT t.*, COALESCE(NULLIF(m.ai_title,''), m.title) AS m_display, m.date AS m_date
                FROM tasks t JOIN meetings m ON m.id = t.meeting_id
                WHERE t.status != 'done' AND (t.owner = ? COLLATE NOCASE OR t.owner = ? COLLATE NOCASE
                                              OR t.owner LIKE ? COLLATE NOCASE)
                ORDER BY m.date DESC
                """, arguments: [name, first, like]).map {
                TaskRow(item: Self.decodeTask($0), meetingTitle: $0["m_display"], meetingDate: $0["m_date"])
            }
            return PersonDetail(meetings: meetings, openTasks: tasks)
        }
    }
}
