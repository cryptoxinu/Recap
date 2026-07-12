import Foundation
import EventKit
import CallBrainCore

/// Calendar initiative C2 — provider abstraction + the hub.
/// Sources produce normalized `CalendarEvent`s; the hub merges, dedupes, links, and feeds the UI.
protocol CalendarSource: Sendable {
    var kind: CalendarEvent.SourceKind { get }
    /// nil = needs connect; false = denied/unavailable; true = live.
    func availability() async -> Bool?
    func connect() async -> Bool
    func events(from: Date, to: Date) async -> [CalendarEvent]
    /// Distinct calendar names for the sources panel.
    func calendarNames() async -> [String]
}

/// Native macOS Calendar (EventKit) — ALSO covers Google/iCloud/Exchange accounts the founder
/// has in Calendar.app, so it's the zero-extra-auth path that usually means "all my calendars".
final class EventKitSource: CalendarSource, @unchecked Sendable {
    let kind = CalendarEvent.SourceKind.eventKit
    // Created LAZILY off-main: EKEventStore init talks to tccd/CalendarAgent and can stall —
    // the founder's pinwheel. Guarded by a lock; only touched from detached tasks.
    private let lock = NSLock()
    private var _store: EKEventStore?
    private func store() -> EKEventStore {
        lock.lock(); defer { lock.unlock() }
        if let s = _store { return s }
        let s = EKEventStore(); _store = s; return s
    }

    func availability() async -> Bool? {
        await Task.detached {
            switch EKEventStore.authorizationStatus(for: .event) {
            case .fullAccess: true
            case .denied, .restricted: false
            default: nil
            }
        }.value
    }

    func connect() async -> Bool {
        await Task.detached { [self] in
            (try? await store().requestFullAccessToEvents()) ?? false
        }.value
    }

    func events(from: Date, to: Date) async -> [CalendarEvent] {
        await Task.detached { [self] in
            guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return [] }
            let s = store()
            // A long-lived store doesn't see accounts added AFTER it opened (founder: "I
            // added my work calendar and it's not showing") — re-pull sources every read.
            s.refreshSourcesIfNecessary()
            let predicate = s.predicateForEvents(withStart: from, end: to, calendars: nil)
            return s.events(matching: predicate).map { ev in
                CalendarEvent(
                    stableID: ev.eventIdentifier ?? "\(ev.calendarItemIdentifier)|\(ev.startDate.timeIntervalSince1970)",
                    sourceKind: .eventKit,
                    calendarName: ev.calendar?.title ?? "Calendar",
                    title: ev.title ?? "Untitled event",
                    start: ev.startDate, end: ev.endDate,
                    attendees: (ev.attendees ?? []).compactMap(\.name),
                    // Include the organizer's email (often the founder on their own calls, or a teammate)
                    // so team-domain learning + team/external classification see it — EventKit omits the
                    // organizer from `attendees` (review MED: a founder-organized call otherwise carried no
                    // team signal). Deduped in the resolver.
                    attendeeEmails: {
                        var e = (ev.attendees ?? []).compactMap { Self.email(of: $0) }
                        if let org = ev.organizer, let oe = Self.email(of: org), !e.contains(oe) { e.append(oe) }
                        return e
                    }(),
                    isAllDay: ev.isAllDay,
                    colorHex: ev.calendar?.color.map { c in
                        let rgb = c.usingColorSpace(.sRGB) ?? c
                        return String(format: "#%02X%02X%02X", Int(rgb.redComponent * 255),
                                      Int(rgb.greenComponent * 255), Int(rgb.blueComponent * 255))
                    },
                    location: ev.location, notes: ev.notes, url: ev.url?.absoluteString,
                    // Holidays/birthdays/subscribed feeds can't be edited — flag them so the
                    // UI hides Edit/drag (audit HIGH).
                    isReadOnly: !(ev.calendar?.allowsContentModifications ?? false),
                    calendarID: ev.calendar?.calendarIdentifier)
            }
        }.value
    }

    /// An attendee's email — EventKit exposes it as a `mailto:` URL, and `.name` is often the raw
    /// email when there's no display name (so we recover a domain even for external guests).
    nonisolated static func email(of p: EKParticipant) -> String? {
        if p.url.scheme?.lowercased() == "mailto" {
            let addr = p.url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
                .trimmingCharacters(in: .whitespaces)
            if addr.contains("@") { return addr.lowercased() }
        }
        if let name = p.name, name.contains("@"), !name.contains(" ") { return name.lowercased() }
        return nil
    }

    func calendarNames() async -> [String] {
        await Task.detached { [self] in
            guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return [] }
            // NOTE: no refreshSourcesIfNecessary here — events() already did it this refresh
            // pass; calling it in all 3 reads amplified remote-source sync (audit MED).
            return store().calendars(for: .event).map(\.title).sorted()
        }.value
    }

    /// Calendar → color hex, for the calendars popover swatches.
    func calendarColors() async -> [String: String] {
        await Task.detached { [self] in
            guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return [:] }
            let s = store()
            var out: [String: String] = [:]
            for cal in s.calendars(for: .event) {
                guard let c = cal.color else { continue }
                let rgb = c.usingColorSpace(.sRGB) ?? c
                out[cal.title] = String(format: "#%02X%02X%02X", Int(rgb.redComponent * 255),
                                        Int(rgb.greenComponent * 255), Int(rgb.blueComponent * 255))
            }
            return out
        }.value
    }
}

/// The hub: owns sources, merges + dedupes their events, runs the linker, feeds the tab.
@MainActor
@Observable
final class CalendarHub {
    private let env: AppEnvironment
    private(set) var sources: [any CalendarSource]
    /// ALL merged+deduped events for the loaded range (unfiltered) — the linker consumes
    /// THIS, so hiding a calendar can never starve the linker.
    private var allEvents: [CalendarEvent] = []
    /// PRE-dedupe ids from the last load — the orphan-prune identity set (audit HIGH: a link
    /// persisted against a twin that dedupe drops is still valid, not an orphan).
    private var loadedEventIDsRaw: [String] = []
    /// VISIBLE events (hidden calendars filtered out), start-ascending — every UI read.
    private(set) var events: [CalendarEvent] = []
    /// eventID → persisted link (Recorded badges + navigation).
    private(set) var links: [String: Store.EventLink] = [:]
    private(set) var calendarNames: [String] = []
    private(set) var calendarColors: [String: String] = [:]
    private(set) var loading = false
    private(set) var eventKitState: Bool??       // nil = probing; .some(nil) = needs connect
    private(set) var loadedRange: ClosedRange<Date>?
    /// Bumped when the background linker lands new links (the tab re-pulls on change).
    private(set) var linksNeedRefresh = 0

    init(env: AppEnvironment) {
        // ZERO IPC here (founder pinwheel): no EKEventStore, no Keychain. Sources finish
        // assembling in probe(), off-main. (UserDefaults is a memory-mapped plist read —
        // the same thing @AppStorage does at view init — not pinwheel material.)
        self.env = env
        self.sources = [EventKitSource()]
        self.hiddenCalendars = Set(UserDefaults.standard.stringArray(forKey: Self.hiddenCalendarsKey) ?? [])
    }
    /// The shared Google source-assembly, awaited by every probe(). Reset to nil when Drive
    /// creds were absent so configuring them later re-enables direct Google without a
    /// relaunch (audit MED).
    private var googleAssembly: Task<Void, Never>?

    /// Runs once per assembly: keychain reads detached (synchronous securityd IPC — pinwheel
    /// material); only Sendable values cross back, sources are constructed on this actor.
    private func assembleGoogleSources() async {
        let found: ((id: String, secret: String)?, [GoogleCalendarSource.Account]) = await Task.detached {
            guard let cfg = KeychainDriveCredentialStore().load(),
                  !cfg.clientID.isEmpty, !cfg.clientSecret.isEmpty else { return (nil, []) }
            return ((cfg.clientID, cfg.clientSecret), GoogleCalendarSource.storedAccounts())
        }.value
        googleCreds = found.0
        guard let creds = googleCreds else {
            // No OAuth client yet — allow a later probe to retry once Drive is set up.
            googleAssembly = nil
            return
        }
        let existingKeys = Set(googleSources.map(\.account.keychainKey))
        for account in found.1 where !existingKeys.contains(account.keychainKey) {
            sources.append(GoogleCalendarSource(clientID: creds.id,
                                                clientSecret: creds.secret, account: account))
        }
        // Legacy/pending tokens have no email — resolve + migrate off-main, best-effort
        // (offline just keeps the "Google account" label), then dedupe: resolution can
        // reveal an account that was ALSO connected explicitly (audit MED).
        let legacies = googleSources.filter { $0.account.email == nil }
        if !legacies.isEmpty {
            let dedupe = self.dedupeGoogleSources
            Task.detached {
                for source in legacies { await source.resolveEmailIfNeeded() }
                await dedupe()
            }
        }
    }

    /// Drops sources that resolved to the same account identity (keeps the first).
    private func dedupeGoogleSources() {
        var seen = Set<String>()
        sources = sources.filter { s in
            guard let g = s as? GoogleCalendarSource else { return true }
            return seen.insert(g.account.keychainKey).inserted
        }
    }

    // MARK: - live system-store changes

    /// macOS posts EKEventStoreChanged when ANY process changes the calendar database —
    /// including a newly added Internet Account finishing its first sync (founder: "I added
    /// my work calendar and it's not showing" — v3 required a relaunch). Debounced: initial
    /// account syncs land as change bursts.
    // nonisolated(unsafe): only ever mutated on the main actor; the nonisolated deinit reads
    // them for cleanup, which is safe because deinit runs when no other reference is live.
    @ObservationIgnored private nonisolated(unsafe) var storeChangeObserver: (any NSObjectProtocol)?
    @ObservationIgnored private nonisolated(unsafe) var storeChangeDebounce: Task<Void, Never>?

    private func observeSystemStoreChanges() {
        guard storeChangeObserver == nil else { return }
        storeChangeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: nil, queue: .main
        ) { _ in
            Task { @MainActor [weak self] in self?.systemStoreChanged() }
        }
    }

    deinit {
        // Best-effort cleanup (the hub is app-lifetime today, so this is belt-and-braces —
        // v3-latecommits audit LOW). removeObserver + Task.cancel are safe off the main actor.
        if let o = storeChangeObserver { NotificationCenter.default.removeObserver(o) }
        storeChangeDebounce?.cancel()
    }

    private func systemStoreChanged() {
        guard eventKitState == .some(true) else { return }
        storeChangeDebounce?.cancel()
        storeChangeDebounce = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            // Re-center on the current window (a paged-away view keeps its place).
            let anchor: Date
            if let range = self.loadedRange {
                anchor = Date(timeIntervalSince1970: (range.lowerBound.timeIntervalSince1970
                                                      + range.upperBound.timeIntervalSince1970) / 2)
            } else {
                anchor = Date()
            }
            await self.refresh(anchor: anchor)
        }
    }

    // MARK: - per-calendar visibility (v3 left rail)

    nonisolated static let hiddenCalendarsKey = "callbrain.calendar.hiddenCalendars"
    private(set) var hiddenCalendars: Set<String> = []

    func isHidden(_ calendarName: String) -> Bool { hiddenCalendars.contains(calendarName) }

    /// Display-only: hidden calendars vanish from every surface, but the linker and
    /// orphan-pruning still see them (allEvents).
    func setCalendar(_ calendarName: String, hidden: Bool) {
        if hidden { hiddenCalendars.insert(calendarName) } else { hiddenCalendars.remove(calendarName) }
        UserDefaults.standard.set(Array(hiddenCalendars).sorted(), forKey: Self.hiddenCalendarsKey)
        rebuildVisibleCaches()   // instant UI from what's in memory…
        // …then re-canonicalize off-main: dedupe prefers non-hidden twins, and that choice
        // was made with the OLD hidden set — a cross-source twin pair could otherwise stay
        // invisible until the next natural refresh.
        if let range = loadedRange {
            let mid = Date(timeIntervalSince1970: (range.lowerBound.timeIntervalSince1970
                                                   + range.upperBound.timeIntervalSince1970) / 2)
            Task { await refresh(anchor: mid) }
        }
    }

    /// Recompute the visible slices from `allEvents` (pure in-memory, O(events × span-days)).
    /// NOTE: visibility is keyed by calendar DISPLAY NAME — the only identity shared across
    /// EventKit and direct Google. Two same-named calendars toggle together (accepted; a
    /// source-qualified key would break the color map and rail grouping for the common case).
    private func rebuildVisibleCaches() {
        let within = loadedRange.map { DateInterval(start: $0.lowerBound, end: $0.upperBound) }
        let b = CalendarMath.buckets(events: allEvents, hidden: hiddenCalendars, within: within)
        events = b.visible
        eventsByDay = b.byDay
        daysWithEvents = b.daysWithEvents
        daysWithLinkedCalls = linkedDays()
        eventsRevision &+= 1
    }

    /// Probe availability (no TCC prompt) — the tab shows Connect only when actually needed.
    /// Also finishes source assembly: the Google keychain reads happen HERE, detached (a
    /// synchronous main-thread securityd call was part of the pinwheel).
    /// Concurrent callers (Settings + Calendar tab) share ONE in-flight assembly (audit MED:
    /// an early latch let the second caller refresh before Google sources were appended).
    func probe() async {
        if googleAssembly == nil {
            googleAssembly = Task { await self.assembleGoogleSources() }
        }
        await googleAssembly?.value
        observeSystemStoreChanges()
        // NOTE: optional chaining FLATTENS (`source?.availability()` is Bool?, not Bool??),
        // so a `?? false` here silently turned notDetermined into "denied" — the founder saw
        // "Calendar access is off" on a fresh install and could never reach the Connect prompt.
        if let ek = sources.first(where: { $0.kind == .eventKit }) {
            eventKitState = .some(await ek.availability())
        } else {
            eventKitState = .some(false)
        }
    }

    func connectEventKit() async {
        guard let s = sources.first(where: { $0.kind == .eventKit }) else { return }
        let ok = await s.connect()
        eventKitState = .some(ok)
        if ok { await refresh() }
    }

    /// Monotonic guard (P3 audit MED): rapid paging fires overlapping refreshes whose detached
    /// work can complete out of order — only the NEWEST may assign state.
    private var refreshGeneration = 0
    /// Bumped whenever `events` is replaced — the shell reconciles the open panel's snapshot.
    private(set) var eventsRevision = 0

    /// Load events around `anchor` (default: 6 weeks back, 6 forward — month grid + linker fuel).
    /// Merge, dedupe, AND day-bucketing all happen off-main; the main actor only assigns results.
    func refresh(anchor: Date = Date()) async {
        refreshGeneration &+= 1
        let gen = refreshGeneration
        loading = true
        // Only clear `loading` if THIS refresh is still the newest — a superseded one
        // finishing late must not drop the flag while the current one is in flight
        // (v3-latecommits audit LOW).
        defer { if gen == refreshGeneration { loading = false } }
        let cal = Calendar.current
        let from = cal.date(byAdding: .day, value: -42, to: anchor)!
        let to = cal.date(byAdding: .day, value: 42, to: anchor)!
        var merged: [CalendarEvent] = []
        var names: [String] = []
        for s in sources {
            merged += await s.events(from: from, to: to)
            names += await s.calendarNames()
        }
        let snapshot = merged
        // Pre-dedupe ids (audit HIGH): pruning must see EVERY loaded id — a link persisted
        // against the twin that dedupe drops is still a valid link, not an orphan.
        let rawIDs = merged.map(\.id)
        let hidden = hiddenCalendars
        let (deduped, visible) = await Task.detached { () -> ([CalendarEvent], CalendarMath.DayBuckets) in
            // Cross-source dedupe: the SAME meeting via EventKit-Google AND direct Google
            // collapses on (normalized title + start-minute). Canonical-twin preference is
            // deterministic (audit HIGH): non-hidden first — hiding one account's calendar
            // must not hide the visible twin — then EventKit (stabler ids), then id.
            var seen = Set<String>()
            let sorted = snapshot.sorted { a, b in
                if a.start != b.start { return a.start < b.start }
                let (ah, bh) = (hidden.contains(a.calendarName) ? 1 : 0,
                                hidden.contains(b.calendarName) ? 1 : 0)
                if ah != bh { return ah < bh }
                let (ak, bk) = (a.sourceKind == .eventKit ? 0 : 1, b.sourceKind == .eventKit ? 0 : 1)
                if ak != bk { return ak < bk }
                return a.id < b.id
            }.filter { e in
                let key = e.title.lowercased().trimmingCharacters(in: .whitespaces)
                    + "|" + String(Int(e.start.timeIntervalSince1970 / 60))
                return seen.insert(key).inserted
            }
            // Visibility filter + multi-day-aware day bucketing (v3): an event lands in EVERY
            // day it intersects (clamped to the loaded window), so a 3-day conference shows
            // on all 3 days and a months-long OOO covers every visible day.
            return (sorted, CalendarMath.buckets(events: sorted, hidden: hidden,
                                                 within: DateInterval(start: from, end: to)))
        }.value
        var colors: [String: String]?
        if let ek = sources.first(where: { $0.kind == .eventKit }) as? EventKitSource {
            colors = await ek.calendarColors()
        }
        // A newer refresh superseded this one while we were off-main — drop everything.
        guard gen == refreshGeneration else { return }
        if let colors { calendarColors = colors }
        allEvents = deduped
        loadedEventIDsRaw = rawIDs
        loadedRange = from...to
        calendarNames = Array(Set(names)).sorted()
        if hidden == hiddenCalendars {
            events = visible.visible
            eventsByDay = visible.byDay
            daysWithEvents = visible.daysWithEvents
        } else {
            // setCalendar ran while the detached work was in flight (audit MED) — the
            // precomputed buckets carry stale visibility; rebuild from current state.
            rebuildVisibleCaches()
        }
        eventsRevision &+= 1
        await refreshLinks()
        runLinker()
    }

    func refreshLinks() async {
        // RAW pre-dedupe ids (audit HIGH): the prune identity set must contain every loaded
        // id — hidden calendars' AND deduped-away twins' — or their valid links get deleted.
        let ids = loadedEventIDsRaw.isEmpty ? allEvents.map(\.id) : loadedEventIDsRaw
        let store = env.store
        // Heal identifier churn BEFORE reading (gate HIGH): links stranded by an EventKit
        // re-identification free their meetings to relink. SKIPPED on empty/failed loads
        // (r2 MED: a provider returning [] must not wipe valid links).
        if let range = loadedRange, !allEvents.isEmpty {
            let (lo, hi) = (range.lowerBound, range.upperBound)
            _ = await Task.detached { try? store.pruneOrphanedEventLinks(loadedEventIDs: ids, rangeStart: lo, rangeEnd: hi) }.value
        }
        links = await Task.detached { (try? store.eventLinks(eventIDs: ids)) ?? [:] }.value
        daysWithLinkedCalls = linkedDays()
    }

    /// Link a just-recorded meeting to a calendar event (auto-record / prep flow). A manual,
    /// definitive link (confidence 1, method "recording") — persisted immediately, then the
    /// tab re-reads links so the Recorded badge appears.
    func linkRecording(eventID: String, meetingID: String) {
        Task { @MainActor in _ = await linkRecordingAwait(eventID: eventID, meetingID: meetingID) }
    }

    /// Awaitable core — returns whether the link actually persisted, so the durable-link reconciler
    /// only drops its pending row after the write SUCCEEDS (P2b audit HIGH: a fire-and-forget link
    /// + unconditional row delete could permanently lose the event link on a transient DB error).
    @discardableResult
    func linkRecordingAwait(eventID: String, meetingID: String) async -> Bool {
        let snapshot = allEvents.first { $0.id == eventID }
        let title = snapshot?.title ?? "Recorded call"
        let start = snapshot?.start ?? Date()
        let store = env.store
        let ok = await AppEnvironment.loggedWrite("linkRecording") {
            try store.saveEventLinks([EventMeetingLinker.Link(
                eventID: eventID, meetingID: meetingID, confidence: 1, method: "recording",
                eventTitle: title, eventStart: start)])
        }
        await refreshLinks()
        return ok
    }

    /// Days whose VISIBLE bucket contains a linked event — bucket-derived (audit LOW) so a
    /// linked multi-day event rings every day it spans, matching what the grid shows.
    private func linkedDays() -> Set<String> {
        let linked = links
        return Set(eventsByDay.filter { _, dayEvents in
            dayEvents.contains { linked[$0.id] != nil }
        }.keys)
    }

    /// Match unlinked meetings against the loaded events on the JobScheduler (background).
    /// Generation-guarded (gate MED): a stale snapshot from a superseded refresh never persists.
    private var linkerGeneration = 0
    nonisolated static let unlinkedPairsKey = "callbrain.calendar.unlinkedPairs"

    func runLinker() {
        linkerGeneration &+= 1
        let gen = linkerGeneration
        let store = env.store, jobs = env.jobs
        // Linked EVENTS are excluded too (integration-audit HIGH: the linker skipped linked
        // meetings but could re-score a linked event against another meeting and MOVE it —
        // links are stable once made; only orphan-pruning or an explicit unlink frees them).
        let linkedIDs = Set(links.keys)
        // allEvents (v3): linking a hidden calendar's events is still correct data.
        let eventsSnapshot = allEvents.filter { !linkedIDs.contains($0.id) }
        let stillCurrent = self.isLinkerGenerationCurrent
        let bump = self.bumpLinksNeedRefresh   // Sendable @MainActor fn values, no self capture
        Task.detached(priority: .utility) {
            await jobs.run(label: "event-linking", priority: .background) {
                let candidates = (try? store.meetingCandidatesForLinking()) ?? []
                guard !candidates.isEmpty, !eventsSnapshot.isEmpty else { return }
                var found = EventMeetingLinker.links(events: eventsSnapshot, meetings: candidates)
                // Durable unlink (gate MED): a pair the founder severed never auto-relinks.
                let dismissed = Set(UserDefaults.standard.stringArray(forKey: CalendarHub.unlinkedPairsKey) ?? [])
                found = found.filter { !dismissed.contains("\($0.eventID)|\($0.meetingID)") }
                guard !found.isEmpty, await stillCurrent(gen) else { return }
                try? store.saveEventLinks(found)
                await bump()   // observed by the tab → re-pulls links
            }
        }
    }

    private func isLinkerGenerationCurrent(_ g: Int) -> Bool { g == linkerGeneration }
    private func bumpLinksNeedRefresh() {
        linksNeedRefresh &+= 1
        env.titlesRevision &+= 1   // open MeetingDetail re-reads its linked-event chip (r2)
    }

    /// Unlink — durable (gate MED): the severed pair is remembered so the linker never
    /// silently re-establishes it.
    func unlink(eventID: String) {
        if let mid = links[eventID]?.meetingID {
            var d = UserDefaults.standard.stringArray(forKey: Self.unlinkedPairsKey) ?? []
            d.append("\(eventID)|\(mid)")
            if d.count > 300 { d.removeFirst(d.count - 300) }   // bounded (r2 LOW)
            UserDefaults.standard.set(Array(Set(d)), forKey: Self.unlinkedPairsKey)
        }
        let store = env.store
        Task { @MainActor in
            _ = await AppEnvironment.loggedWrite("deleteEventLink") { try store.deleteEventLink(eventID: eventID) }
            links[eventID] = nil
        }
    }

    /// Drive's OAuth client creds (shared with Calendar) — set during probe(), needed to
    /// construct sources for newly connected accounts.
    private var googleCreds: (id: String, secret: String)?
    /// True when the OAuth client is configured (the connect affordances can show).
    var googleConfigured: Bool { googleCreds != nil }
    var googleSources: [GoogleCalendarSource] {
        sources.compactMap { $0 as? GoogleCalendarSource }
    }
    /// Connected direct-Google accounts, for Settings + the rail.
    var googleAccounts: [GoogleCalendarSource.Account] { googleSources.map(\.account) }
    private(set) var googleConnected: Bool? = nil
    /// Honest Google outcome for the rail/Settings: error, or "N events (M new after dedupe)".
    private(set) var googleStatus: String?

    func probeGoogle() async {
        googleConnected = googleSources.isEmpty ? nil : true
    }

    /// Connect ANOTHER Google account (founder: "add gmail accounts") — never replaces an
    /// existing one; each account's refresh token lives under its own keychain key.
    func connectGoogle() async {
        guard let creds = googleCreds else {
            googleStatus = "Set up the Google client under Settings → Google Drive first."
            return
        }
        guard let account = await GoogleCalendarSource.connectNewAccount(clientID: creds.id,
                                                                         clientSecret: creds.secret) else {
            googleStatus = "Google sign-in didn't complete."
            return
        }
        // Replace any stale source for the same keychain key (reconnect case), then add.
        sources.removeAll { ($0 as? GoogleCalendarSource)?.account.keychainKey == account.keychainKey }
        let g = GoogleCalendarSource(clientID: creds.id, clientSecret: creds.secret, account: account)
        sources.append(g)
        googleConnected = true
        await refresh()
        // Explain what connecting actually ADDED (founder: "nothing showed up" — usually
        // because these Google accounts already sync through macOS Calendar, so direct events
        // dedupe away; that's correct, but it must be SAID, not silent).
        if let err = g.lastStatus {
            googleStatus = err
        } else {
            let from = Calendar.current.date(byAdding: .day, value: -42, to: Date())!
            let to = Calendar.current.date(byAdding: .day, value: 42, to: Date())!
            let direct = await g.events(from: from, to: to)
            if direct.isEmpty {
                googleStatus = "\(account.display) connected — no events found in this window."
            } else {
                let existing = Set(allEvents.map(\.id))
                let new = direct.filter { existing.contains($0.id) }.count
                googleStatus = new > 0
                    ? "\(account.display) connected — \(direct.count) events, \(new) shown."
                    : "\(account.display) connected — \(direct.count) events, all already here via your macOS Calendar accounts (deduplicated)."
            }
        }
    }

    /// Disconnect one direct-Google account: token deleted, its events drop on the awaited
    /// refresh right here (sub-second stale window — accepted; events can't be attributed
    /// to an account post-merge without a bigger model change).
    func disconnectGoogle(_ account: GoogleCalendarSource.Account) async {
        let deleted = googleSources.first { $0.account.keychainKey == account.keychainKey }?
            .disconnect() ?? true
        sources.removeAll { ($0 as? GoogleCalendarSource)?.account.keychainKey == account.keychainKey }
        googleConnected = googleSources.isEmpty ? nil : true
        googleStatus = deleted
            ? "\(account.display) disconnected."
            : "\(account.display) removed, but the stored sign-in couldn't be deleted — try again."
        await refresh()
    }

    // MARK: - UI queries (cached — the month grid reads these 35× per layout pass)

    private(set) var eventsByDay: [String: [CalendarEvent]] = [:]
    private(set) var daysWithEvents: Set<String> = []
    private(set) var daysWithLinkedCalls: Set<String> = []

    /// Events on one local day, start-ascending.
    func events(onYMD ymd: String) -> [CalendarEvent] { eventsByDay[ymd] ?? [] }

    /// The timed calendar event happening RIGHT NOW (with a 5-min grace on each side so a call joined a
    /// few minutes early/late still matches), best-overlap first. Used to auto-link a manual recording to
    /// the scheduled call the founder is on. Returns nil if the calendar isn't loaded or nothing overlaps.
    func eventHappeningNow(now: Date = Date(), grace: TimeInterval = 5 * 60) -> CalendarEvent? {
        EventMeetingLinker.happeningNow(events, now: now, grace: grace)
    }

    /// The next events from now (the "Upcoming" pane).
    func upcoming(limit: Int = 8) -> [CalendarEvent] {
        let now = Date()
        return events.filter { $0.end > now && !$0.isAllDay }.prefix(limit).map { $0 }
    }
}
