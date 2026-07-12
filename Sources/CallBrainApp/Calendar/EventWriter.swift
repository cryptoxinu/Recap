import Foundation
import EventKit
import CallBrainCore

/// Calendar v4 — writes events to the macOS calendar store (EventKit). The Full Access we
/// already hold grants write, so create/edit/delete need no new prompt. ALL work is off-main
/// (EventKit is a tccd/CalendarAgent IPC — the pinwheel risk). Google-source events are
/// read-only this pass (they'd need a `calendar.events` OAuth re-consent) and return a reason.
///
/// EventKit's public API can't set arbitrary attendees, so typed attendees are folded into the
/// notes as an "Attendees:" line — honest, and they still show up when the event opens.
enum EventWriter {

    enum WriteError: LocalizedError {
        case readOnlyGoogle
        case noWritableCalendar
        case eventNotFound
        case underlying(String)
        var errorDescription: String? {
            switch self {
            case .readOnlyGoogle: "This event is on a directly-connected Google calendar, which is read-only here. Edit it in Google Calendar, or add the account to macOS Calendar."
            case .noWritableCalendar: "No writable calendar is available to save to."
            case .eventNotFound: "That event no longer exists in your calendar."
            case .underlying(let m): m
            }
        }
    }

    /// Writable EventKit calendars for the editor's calendar picker — carries the owning
    /// ACCOUNT (source) so the founder sees "which account" they're adding to.
    struct WritableCalendar: Sendable, Identifiable, Equatable {
        let id: String; let title: String; let colorHex: String?
        let account: String        // EKSource.title — "iCloud", "you@company.com", "Google"
        let isDefault: Bool
    }

    static func writableCalendars() async -> [WritableCalendar] {
        await Task.detached {
            guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return [] }
            let s = EKEventStore()
            let defaultID = s.defaultCalendarForNewEvents?.calendarIdentifier
            return s.calendars(for: .event)
                .filter { $0.allowsContentModifications }
                .map { c in
                    let hex = c.color.map { col -> String in
                        let rgb = col.usingColorSpace(.sRGB) ?? col
                        return String(format: "#%02X%02X%02X", Int(rgb.redComponent*255),
                                      Int(rgb.greenComponent*255), Int(rgb.blueComponent*255))
                    }
                    return WritableCalendar(id: c.calendarIdentifier, title: c.title, colorHex: hex,
                                            account: c.source?.title ?? "Calendar",
                                            isDefault: c.calendarIdentifier == defaultID)
                }
                // Group by account, default calendar first within each.
                .sorted { a, b in
                    if a.account != b.account { return a.account < b.account }
                    if a.isDefault != b.isDefault { return a.isDefault }
                    return a.title < b.title
                }
        }.value
    }

    /// Create a new event. Returns the new event's source-qualified id ("eventKit|<id>").
    @discardableResult
    static func create(_ draft: EventDraft) async throws -> String {
        try await Task.detached {
            let s = EKEventStore()
            guard let cal = targetCalendar(draft.calendarName, store: s) else { throw WriteError.noWritableCalendar }
            let ev = EKEvent(eventStore: s)
            apply(draft, to: ev, calendar: cal, foldAttendees: true)
            do { try s.save(ev, span: .thisEvent, commit: true) }
            catch { throw WriteError.underlying(error.localizedDescription) }
            return "eventKit|\(ev.eventIdentifier ?? "")"
        }.value
    }

    /// Update an existing EventKit event. Refuses read-only (Google, holidays, subscribed).
    static func update(_ event: CalendarEvent, with draft: EventDraft) async throws {
        guard event.sourceKind == .eventKit, !event.isReadOnly else { throw WriteError.readOnlyGoogle }
        try await Task.detached {
            let s = EKEventStore()
            guard let ev = occurrence(of: event, store: s) else { throw WriteError.eventNotFound }
            guard ev.calendar?.allowsContentModifications == true else { throw WriteError.readOnlyGoogle }
            let cal = targetCalendar(draft.calendarName, store: s) ?? ev.calendar
            apply(draft, to: ev, calendar: cal, foldAttendees: false)
            do { try s.save(ev, span: .thisEvent, commit: true) }
            catch { throw WriteError.underlying(error.localizedDescription) }
        }.value
    }

    /// Delete an EventKit event. Refuses read-only events; targets the exact occurrence.
    static func delete(_ event: CalendarEvent) async throws {
        guard event.sourceKind == .eventKit, !event.isReadOnly else { throw WriteError.readOnlyGoogle }
        try await Task.detached {
            let s = EKEventStore()
            guard let ev = occurrence(of: event, store: s) else { throw WriteError.eventNotFound }
            guard ev.calendar?.allowsContentModifications == true else { throw WriteError.readOnlyGoogle }
            do { try s.remove(ev, span: .thisEvent, commit: true) }
            catch { throw WriteError.underlying(error.localizedDescription) }
        }.value
    }

    /// Move/resize only (drag): change just the times on the exact occurrence — never touches
    /// notes/attendees (audit MED).
    static func reschedule(_ event: CalendarEvent, start: Date, end: Date) async throws {
        guard event.sourceKind == .eventKit, !event.isReadOnly else { throw WriteError.readOnlyGoogle }
        try await Task.detached {
            let s = EKEventStore()
            guard let ev = occurrence(of: event, store: s) else { throw WriteError.eventNotFound }
            guard ev.calendar?.allowsContentModifications == true else { throw WriteError.readOnlyGoogle }
            ev.startDate = start
            ev.endDate = max(end, start.addingTimeInterval(60))
            do { try s.save(ev, span: .thisEvent, commit: true) }
            catch { throw WriteError.underlying(error.localizedDescription) }
        }.value
    }

    /// QA-only: remove any events with an exact title in a ±1-day window (self-test cleanup).
    static func sweepByTitle(_ title: String, near date: Date) async {
        await Task.detached {
            guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return }
            let s = EKEventStore()
            let day: TimeInterval = 86_400
            let pred = s.predicateForEvents(withStart: date.addingTimeInterval(-day),
                                            end: date.addingTimeInterval(day), calendars: nil)
            for ev in s.events(matching: pred) where ev.title == title
                && (ev.calendar?.allowsContentModifications ?? false) {
                try? s.remove(ev, span: .thisEvent, commit: true)
            }
        }.value
    }

    // MARK: - helpers (run inside the detached store context)

    /// Resolve the EXACT occurrence (audit HIGH: `event(withIdentifier:)` returns the FIRST
    /// occurrence of a recurring series — editing it would hit the wrong instance). Fetch the
    /// events overlapping the known start and match by identifier + start.
    private static func occurrence(of event: CalendarEvent, store s: EKEventStore) -> EKEvent? {
        let pad: TimeInterval = 60
        let predicate = s.predicateForEvents(withStart: event.start.addingTimeInterval(-pad),
                                             end: event.end.addingTimeInterval(pad), calendars: nil)
        let matches = s.events(matching: predicate)
        // Exact occurrence: same identifier AND same start (the one the user sees).
        if let exact = matches.first(where: {
            $0.eventIdentifier == event.stableID && abs($0.startDate.timeIntervalSince(event.start)) < 1
        }) { return exact }
        // Unambiguous single instance in the window → safe to use.
        let idMatches = matches.filter { $0.eventIdentifier == event.stableID }
        if idMatches.count == 1 { return idMatches[0] }
        // Ambiguous recurring series (or none in-window) → FAIL CLOSED rather than risk
        // editing the wrong occurrence via event(withIdentifier:)'s first-occurrence rule
        // (audit HIGH). The caller surfaces "event no longer exists" and the user retries.
        return nil
    }

    /// Resolve the target calendar. When an explicit id/name is given it MUST resolve to a
    /// writable calendar — returns nil if it doesn't so the caller can fail rather than
    /// silently write to the default (final-audit HIGH). Only a nil name falls back to default.
    private static func targetCalendar(_ name: String?, store s: EKEventStore) -> EKCalendar? {
        let writable = s.calendars(for: .event).filter { $0.allowsContentModifications }
        if let name {
            if let byID = s.calendar(withIdentifier: name), byID.allowsContentModifications { return byID }
            if let byTitle = writable.first(where: { $0.title == name }) { return byTitle }
            return nil   // explicit selection that no longer resolves → caller decides
        }
        return s.defaultCalendarForNewEvents ?? writable.first
    }

    private static func apply(_ d: EventDraft, to ev: EKEvent, calendar: EKCalendar?, foldAttendees: Bool) {
        ev.title = d.title
        ev.isAllDay = d.isAllDay
        if d.isAllDay {
            // All-day uses an EXCLUSIVE end. The draft's end is ALREADY exclusive (parser +
            // editor produce [day, nextDay)) — normalize both to start-of-day and DON'T add a
            // day, or a no-op save would stretch a 1-day event to 2 (audit HIGH). Floor at
            // one day.
            let cal = Calendar.current
            let s0 = cal.startOfDay(for: d.start)
            ev.startDate = s0
            let endDay = cal.startOfDay(for: d.end)
            let minEnd = cal.date(byAdding: .day, value: 1, to: s0)!
            ev.endDate = max(endDay, minEnd)
        } else {
            ev.startDate = d.start
            ev.endDate = max(d.end, d.start.addingTimeInterval(60))
        }
        ev.location = d.location
        if let cal = calendar { ev.calendar = cal }
        // EventKit can't set real attendees via public API. On CREATE we fold the typed names
        // into notes once (notes start empty — no external content to clobber). On UPDATE we
        // NEVER rewrite notes for attendees (final-audit: that compounded, or clobbered an
        // external event whose notes legitimately began "Attendees:") — the notes field is
        // authoritative and the editor tells the user attendee edits don't persist.
        let base = d.notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if foldAttendees, !d.attendees.isEmpty {
            let line = "Attendees: " + d.attendees.joined(separator: ", ")
            ev.notes = base.isEmpty ? line : "\(line)\n\n\(base)"
        } else {
            ev.notes = base.isEmpty ? nil : base
        }
    }
}
