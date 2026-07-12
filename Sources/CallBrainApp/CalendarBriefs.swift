import Foundation
import EventKit
import CallBrainCore

/// Perfection plan Task 9.2 — calendar prep briefs: "Your 2pm with Riley — last call's
/// decisions and open items." EventKit access is asked LAZILY from the Home chip (TCC gate);
/// a denial hides the feature permanently and gracefully (critic #2).
@MainActor
@Observable
final class CalendarBriefs {
    struct Brief: Identifiable, Equatable {
        let id: String              // event identifier
        let title: String
        let start: Date
        let attendee: String?       // the first attendee we recognize from People
        let lastMeetingID: String?  // their most recent call, for one-tap prep
        let openTaskCount: Int
    }

    enum State: Equatable { case unknown, denied, authorized }
    private(set) var state: State = .unknown
    private(set) var briefs: [Brief] = []
    // Lazy — EKEventStore init talks to tccd/CalendarAgent and can stall the main thread.
    @ObservationIgnored private var _eventStore: EKEventStore?
    private var eventStore: EKEventStore {
        if let s = _eventStore { return s }
        let s = EKEventStore(); _eventStore = s; return s
    }
    static let declinedKey = "callbrain.calendar.declined"   // user said no to the CHIP (not TCC)

    /// OBSERVED mirror of the persisted "declined" flag — the chip's dismiss button mutates this so
    /// SwiftUI actually re-renders. Reading UserDefaults directly in `chipVisible` meant tapping ✕
    /// changed no tracked property, so the chip never disappeared (audit G2 HIGH — dead button).
    private var declined = false

    var chipVisible: Bool {
        state != .denied && !declined
    }

    init() {
        declined = UserDefaults.standard.bool(forKey: Self.declinedKey)
        // Reflect an existing TCC decision without prompting.
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: state = .authorized
        case .denied, .restricted: state = .denied
        default: state = .unknown
        }
    }

    /// The Home chip's action — triggers the TCC prompt exactly once.
    func connect(store: Store) async {
        do {
            let granted = try await eventStore.requestFullAccessToEvents()
            state = granted ? .authorized : .denied
        } catch { state = .denied }
        if state == .authorized { await refresh(store: store) }
    }

    func declineChip() {
        declined = true                                             // observed → the chip re-renders away
        UserDefaults.standard.set(true, forKey: Self.declinedKey)   // + persist the choice
    }

    /// Today's REMAINING events, matched to known people by attendee name. The EventKit query
    /// runs OFF-main (integration-audit HIGH: `events(matching:)` is a synchronous CalendarAgent
    /// round-trip — the surviving 300-550ms Home stall candidate after the hub fix).
    func refresh(store: Store) async {
        guard state == .authorized else { return }
        let now = Date()
        struct Snap: Sendable { let title: String; let start: Date; let names: [String]; let id: String }
        let snaps: [Snap] = await Task.detached {
            let cal = Calendar.current
            let end = cal.date(bytesOrEndOfDay: now)
            let es = EKEventStore()   // detached-local store; cheap once TCC is settled
            let predicate = es.predicateForEvents(withStart: now, end: end, calendars: nil)
            return es.events(matching: predicate)
                .filter { !$0.isAllDay }
                .sorted { $0.startDate < $1.startDate }
                .prefix(4)
                .map { ev in Snap(title: ev.title ?? "Meeting", start: ev.startDate,
                                  names: (ev.attendees ?? []).compactMap(\.name) + [ev.title ?? ""],
                                  id: ev.eventIdentifier ?? UUID().uuidString) }
        }.value
        let events = snaps

        // Same grounded roster as the People tab; exclude the user's own aliases so a self-match never
        // becomes a "known attendee" brief.
        let exclude = Set(FounderIdentity.aliases)
        let people = await Task.detached { (try? store.people(excluding: exclude)) ?? [] }.value
        var out: [Brief] = []
        for ev in events {
            let known = people.first { p in
                let first = p.name.split(separator: " ").first.map(String.init) ?? p.name
                return ev.names.contains { $0.localizedCaseInsensitiveContains(first) }
            }
            var lastMeeting: String?
            var openTasks = 0
            if let known {
                let detail = await Task.detached { try? store.personDetail(name: known.name) }.value
                lastMeeting = detail?.meetings.first?.id
                openTasks = detail?.openTasks.count ?? 0
            }
            out.append(Brief(id: ev.id, title: ev.title, start: ev.start,
                             attendee: known?.name,
                             lastMeetingID: lastMeeting,
                             openTaskCount: openTasks))
        }
        briefs = out
    }
}

private extension Calendar {
    func date(bytesOrEndOfDay from: Date) -> Date {
        date(bySettingHour: 23, minute: 59, second: 59, of: from) ?? from.addingTimeInterval(86_400)
    }
}
