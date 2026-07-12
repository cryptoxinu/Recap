import Foundation

/// Perfection plan Task 2.3 — pairs the two halves of the SAME call (a `gmeet_gemini` notes doc
/// and a transcript meeting) so they can be merged into one. The production corpus was fully
/// double-ingested: 8 notes + 8 recordings of the same 8 calls (audit CRITICAL — retrieval
/// double-counts, tasks duplicate, date-scoped answers fight their own twins).
///
/// Matching is deliberately conservative: same DATE, plus a strong signal — a normalized-title
/// prefix relationship OR an exact time-of-day token shared by both titles. A gemini doc with
/// two equally-plausible transcripts is SKIPPED (ambiguity goes to the review UI, never a guess).
public enum CrossSourceLinker {

    public struct Pair: Sendable, Equatable {
        public let gemini: Store.MeetingRow
        public let transcript: Store.MeetingRow
        public let reason: String
    }

    /// Transcript-side sources that can host a merge (verbatim content wins as survivor).
    static let transcriptSources: Set<String> = [
        MeetingSource.gmeetLocal.rawValue, MeetingSource.gmeetCloud.rawValue,
        MeetingSource.gmeetCaptions.rawValue,   // T2: Meet CC captions are a verbatim transcript source too
        MeetingSource.fathom.rawValue, MeetingSource.fireflies.rawValue,
    ]

    /// Normalize a title for prefix comparison: lowercase, strip the date/recording tail
    /// ("morning sync - 2026-06-24 09-27 PDT - Recording-1T3T" → "morning sync";
    ///  "yve-ucys-mqb (2026-06-24 12-32 GMT-7)-1am…" → "yve-ucys-mqb").
    static func normTitle(_ t: String) -> String {
        var s = t.lowercased()
        if let r = s.range(of: #"\s*[-–(]\s*\d{4}[-_]\d{2}[-_]\d{2}"#, options: .regularExpression) {
            s = String(s[..<r.lowerBound])
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "HH-MM" time-of-day token if the title carries one next to a date ("2026-06-24 10-09").
    static func timeToken(_ t: String) -> String? {
        guard let r = t.range(of: #"\d{4}[-_]\d{2}[-_]\d{2}[ _](\d{2}[-_]\d{2})"#, options: .regularExpression) else { return nil }
        let match = String(t[r])
        return String(match.suffix(5)).replacingOccurrences(of: "_", with: "-")
    }

    /// The two titles describe the same call: one normalized title prefixes the other (min length
    /// guards against "" matching everything).
    static func titlesMatch(_ a: String, _ b: String) -> Bool {
        let na = normTitle(a), nb = normTitle(b)
        guard na.count >= 4, nb.count >= 4 else { return false }
        return na.hasPrefix(nb) || nb.hasPrefix(na)
    }

    /// Both titles carry a time token AND they disagree → these are DIFFERENT calls, whatever
    /// the titles say (Codex phase-2 HIGH: two same-title calls on one day must never merge).
    static func timeConflict(_ a: String, _ b: String) -> Bool {
        guard let ta = timeToken(a), let tb = timeToken(b) else { return false }
        return ta != tb
    }

    /// Same-date gemini↔transcript pairs with exactly one strong match each, a time-conflict
    /// veto, and a person-overlap sanity veto (when BOTH sides know their people and share
    /// none, they are different calls — merging is destructive, so any doubt means skip).
    public static func candidates(store: Store) throws -> [Pair] {
        let all = try store.meetings(fromYMD: "2000-01-01", toYMDExclusive: "2100-01-01", limit: 10_000)
        let geminis = all.filter { $0.source == MeetingSource.gmeetGemini.rawValue }
        let transcripts = all.filter { transcriptSources.contains($0.source) }

        func peopleCompatible(_ a: Store.MeetingRow, _ b: Store.MeetingRow) -> Bool {
            guard let pa = try? store.personEntityNames(meetingID: a.id),
                  let pb = try? store.personEntityNames(meetingID: b.id),
                  !pa.isEmpty, !pb.isEmpty else { return true }   // unknown people → no signal
            return !pa.isDisjoint(with: pb)
        }

        var pairs: [Pair] = []
        for g in geminis {
            let sameDay = transcripts.filter { $0.date == g.date && !timeConflict(g.title, $0.title) }
            let timeMatches = timeToken(g.title).map { gt in
                sameDay.filter { timeToken($0.title) == gt }
            } ?? []
            let titleMatches = sameDay.filter { titlesMatch(g.title, $0.title) }

            let pick: (Store.MeetingRow, String)?
            if timeMatches.count == 1 {
                pick = (timeMatches[0], "time \(timeToken(g.title)!) on \(g.date)")
            } else if timeMatches.isEmpty && titleMatches.count == 1 {
                pick = (titleMatches[0], "title '\(normTitle(g.title))' on \(g.date)")
            } else {
                pick = nil   // 0 → nothing to link; ≥2 → ambiguous, review UI's call
            }
            if let (t, reason) = pick, peopleCompatible(g, t) {
                pairs.append(Pair(gemini: g, transcript: t, reason: reason))
            }
        }
        // A transcript claimed by two geminis is ambiguous from the other side — drop both claims.
        var seen: [String: Int] = [:]
        for p in pairs { seen[p.transcript.id, default: 0] += 1 }
        return pairs.filter { seen[$0.transcript.id] == 1 }
    }
}
