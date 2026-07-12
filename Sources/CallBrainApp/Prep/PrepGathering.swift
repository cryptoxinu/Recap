import Foundation
import CallBrainCore

/// Calendar v4 — turns an upcoming calendar event + the Store into the `CallPrep.Candidate`
/// set that `CallPrep.assemble` ranks. All reads are synchronous GRDB; call OFF the main
/// actor (Store is @unchecked Sendable). The pure ranking lives in CallPrep (tested); this is
/// just the mechanical corpus gather.
enum PrepGather {

    /// Candidate past meetings relevant to the event: those with a matching attendee (via
    /// `personDetail`) unioned with title-series matches from recent meetings. Capped by
    /// recency so a big archive stays cheap.
    static func candidates(event: CalendarEvent, store: Store,
                           calendar: Calendar = .current, cap: Int = 30) -> [CallPrep.Candidate] {
        let eventYMD = TimeCode.ymd(event.start, calendar: calendar)
        var picked: [String: Store.MeetingRow] = [:]   // meetingID → row

        // 1. Attendee-matched meetings (personDetail prefix-matches names both ways).
        for name in event.attendees {
            let first = name.split(separator: " ").first.map(String.init) ?? name
            guard first.count >= 2 else { continue }
            if let detail = try? store.personDetail(name: name) {
                for m in detail.meetings where m.date < eventYMD || m.date == eventYMD { picked[m.id] = m }
            }
        }

        // 2. Title-series matches from recent meetings (catches recurring calls even when the
        // provider gave us no attendee list). Only meaningful overlaps.
        if let recents = try? store.recentMeetings(limit: 400) {
            for m in recents where m.date <= eventYMD {
                if picked[m.id] == nil,
                   EventMeetingLinker.titleSimilarity(event.title, m.displayTitle) >= 0.5 {
                    picked[m.id] = m
                }
            }
        }

        // Newest first, capped.
        let rows = picked.values.sorted { ($0.date, $0.id) > ($1.date, $1.id) }.prefix(cap)
        let ids = rows.map(\.id)
        // Generous cap: this set GROUNDS commitment owners (an owner not in it is shown unattributed),
        // so under-including real participants wrongly nulls valid owners (Codex-audit HIGH). Person
        // entities per call rarely exceed ~20; 64 is effectively "all real participants".
        let peopleByMeeting = (try? store.meetingPeople(ids: ids, perMeeting: 64)) ?? [:]

        return rows.map { m in
            let allTasks = (try? store.tasks(meetingID: m.id)) ?? []
            let openTasks = allTasks.filter { $0.status != .done }.map { (owner: $0.owner, text: $0.text) }
            let resolvedTasks = allTasks.filter { $0.status == .done }.map { (owner: $0.owner, text: $0.text) }
            return CallPrep.Candidate(
                meetingID: m.id, title: m.displayTitle, date: m.date,
                oneLiner: m.aiSummary, summary: m.callSummary,
                people: peopleByMeeting[m.id] ?? [], openTasks: openTasks, resolvedTasks: resolvedTasks)
        }
    }

    /// Full free context for an event, gathered off-main.
    static func context(event: CalendarEvent, store: Store,
                        calendar: Calendar = .current) -> CallPrep.Context {
        let cands = candidates(event: event, store: store, calendar: calendar)
        return CallPrep.assemble(eventTitle: event.title, start: event.start,
                                 attendees: event.attendees, candidates: cands)
    }

    /// Context AUGMENTED with semantic (embedding) past-call matches (prep FIX 6): a topically-relevant
    /// prior call is found even with a different title + different attendees. Best-effort — if the embedder
    /// is down it returns exactly the lexical `context`. Async (embeds the event topic); call off-main.
    static func context(event: CalendarEvent, store: Store, search: SearchEngine,
                        calendar: Calendar = .current) async -> CallPrep.Context {
        let lexical = candidates(event: event, store: store, calendar: calendar)
        let semantic = await semanticCandidates(event: event, store: store, search: search,
                                                excluding: Set(lexical.map(\.meetingID)), calendar: calendar)
        return CallPrep.assemble(eventTitle: event.title, start: event.start,
                                 attendees: event.attendees, candidates: lexical + semantic)
    }

    /// Past calls semantically similar to the event's topic, that the lexical lanes MISSED (different
    /// title, no shared attendee). Scored by absolute max-cosine so `CallPrep.assemble`'s `semanticFloor`
    /// gates them consistently. Only PAST calls; capped.
    static func semanticCandidates(event: CalendarEvent, store: Store, search: SearchEngine,
                                   excluding: Set<String>, calendar: Calendar = .current,
                                   cap: Int = 5) async -> [CallPrep.Candidate] {
        let query = ([event.title] + event.attendees).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        let byMeeting: [String: Double]
        do { byMeeting = try await search.meetingRelevance(query) }
        catch is CancellationError { return [] }   // a reloaded/dismissed card cancelled the gather
        catch { return [] }                         // embedder down → lexical-only
        guard !byMeeting.isEmpty else { return [] }
        let eventYMD = TimeCode.ymd(event.start, calendar: calendar)
        // Strong, not-already-lexical matches, best-first — NOT yet capped.
        let ranked = byMeeting
            .filter { !excluding.contains($0.key) && $0.value >= CallPrep.semanticFloor }
            .sorted { $0.value > $1.value }
        guard !ranked.isEmpty else { return [] }
        let ids = ranked.map { $0.key }
        let rows = (try? store.meetings(ids: ids)) ?? [:]
        let peopleByMeeting = (try? store.meetingPeople(ids: ids, perMeeting: 64)) ?? [:]
        // Apply the PAST-only guard BEFORE the cap (audit MED) — so a run of future-dated top matches
        // doesn't starve real past ones ranked just behind them.
        var out: [CallPrep.Candidate] = []
        for entry in ranked {
            guard out.count < cap else { break }
            guard let m = rows[entry.key], m.date <= eventYMD else { continue }   // PAST calls only
            let allTasks = (try? store.tasks(meetingID: m.id)) ?? []
            let openTasks = allTasks.filter { $0.status != .done }.map { (owner: $0.owner, text: $0.text) }
            let resolvedTasks = allTasks.filter { $0.status == .done }.map { (owner: $0.owner, text: $0.text) }
            out.append(CallPrep.Candidate(
                meetingID: m.id, title: m.displayTitle, date: m.date,
                oneLiner: m.aiSummary, summary: m.callSummary,
                people: peopleByMeeting[m.id] ?? [], openTasks: openTasks,
                resolvedTasks: resolvedTasks, semanticScore: entry.value))
        }
        return out
    }
}
