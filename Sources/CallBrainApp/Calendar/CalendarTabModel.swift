import SwiftUI
import CallBrainCore

/// Calendar v3 — all tab UI state + intents, no views. The shell and every subview mutate
/// state ONLY through these methods so selection/paging/refresh policy lives in one place.
@MainActor
@Observable
final class CalendarTabModel {

    /// v4: Agenda is now its OWN sidebar tab — the calendar switcher is just Month/Week/Day.
    enum Mode: String, CaseIterable, Identifiable {
        case month, week, day        // order = pill order (M | W | D)
        var id: String { rawValue }
        var title: String {
            switch self {
            case .week: "Week"
            case .day: "Day"
            case .month: "Month"
            }
        }
        var short: String {          // pill label
            switch self {
            case .month: "M"
            case .week: "W"
            case .day: "D"
            }
        }
    }

    static let modeKey = "callbrain.calendar.mode"

    var mode: Mode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey) }
    }
    /// The focused day; week/month derive their containing unit from it.
    private(set) var anchor: Date
    /// Agenda + mini-month selection (kept distinct from anchor, like v2).
    private(set) var selectedYMD: String
    /// VALUE snapshot — the open panel survives a refresh() replacing hub.events.
    private(set) var selected: CalendarEvent?
    /// Bump counter; the week grid observes and scrolls to the now-line.
    private(set) var scrollToNowRequest = 0

    init(now: Date = Date()) {
        // One-time v3 seed: the Notion default is Week. A v2-era stored "month"/"agenda"
        // predates the week view existing, so it isn't a real preference — seed once, then
        // respect whatever the founder picks from here on.
        let seededKey = "callbrain.calendar.v3SeededWeek"
        if !UserDefaults.standard.bool(forKey: seededKey) {
            UserDefaults.standard.set(true, forKey: seededKey)
            UserDefaults.standard.set(Mode.week.rawValue, forKey: Self.modeKey)
        }
        let raw = UserDefaults.standard.string(forKey: Self.modeKey) ?? Mode.week.rawValue
        // QA deep-link (smoke/screenshots): force a mode WITHOUT touching the persisted pref
        // (didSet doesn't fire in init).
        if let forced = ProcessInfo.processInfo.environment["CALLBRAIN_CAL_MODE"],
           let m = Mode(rawValue: forced) {
            self.mode = m
        } else {
            // v4: a stored "agenda" (now a separate tab) or any unknown value → Week.
            self.mode = Mode(rawValue: raw) ?? .week
        }
        self.anchor = now
        self.selectedYMD = TimeCode.ymd(now)
    }

    // MARK: - intents

    func setMode(_ m: Mode, hub: CalendarHub) {
        guard m != mode else { return }
        // Entering a single-day mode follows the SELECTED day (final-gate MED: month
        // single-click selects without re-anchoring, so pressing D must open that day,
        // not wherever the anchor last was).
        if m == .day, let d = CalendarMath.date(fromYMD: selectedYMD) {
            anchor = d
        }
        withAnimation(.easeInOut(duration: 0.15)) { mode = m }
        ensureLoaded(hub: hub)
    }

    /// ‹ › paging — the unit follows the mode.
    func page(_ delta: Int, hub: CalendarHub) {
        let cal = Calendar.current
        let unit: Calendar.Component = switch mode {
        case .week: .weekOfYear
        case .day: .day
        case .month: .month
        }
        anchor = cal.date(byAdding: unit, value: delta, to: anchor) ?? anchor
        if mode == .day { selectedYMD = TimeCode.ymd(anchor) }
        ensureLoaded(hub: hub)
    }

    func goToday(hub: CalendarHub) {
        withAnimation(Theme.smooth) {
            anchor = Date()
            selectedYMD = TimeCode.ymd(anchor)
        }
        scrollToNowRequest &+= 1
        ensureLoaded(hub: hub)
    }

    /// Mini-month / header day click — moves the anchor (navigates).
    func focus(day: Date, hub: CalendarHub, switchTo newMode: Mode? = nil) {
        anchor = day
        selectedYMD = TimeCode.ymd(day)
        if let newMode { setMode(newMode, hub: hub) } else { ensureLoaded(hub: hub) }
    }

    /// Month-cell SINGLE click — selection only, never re-anchors (P3 audit MED: single-click
    /// on an adjacent-month cell re-anchored the board mid-double-click, so the second click
    /// landed on a different cell).
    func selectDay(_ day: Date) {
        selectedYMD = TimeCode.ymd(day)
    }

    func select(_ e: CalendarEvent?) { selected = e }

    /// After the hub replaces events (P3 audit LOW): re-point the open panel's value snapshot
    /// at the refreshed twin so it never shows stale title/time/notes. If the event left the
    /// loaded window, the snapshot stays — better than yanking the panel shut.
    func reconcileSelection(hub: CalendarHub) {
        guard let sel = selected else { return }
        // If the selected event's calendar was hidden, close the panel — otherwise a hidden
        // event stays editable/deletable from a stale snapshot (final-audit MED).
        if hub.isHidden(sel.calendarName) { selected = nil; return }
        guard let fresh = hub.events.first(where: { $0.id == sel.id }) else { return }
        if fresh != sel { selected = fresh }
    }

    /// Re-center the hub's 84-day window when the mode's visible interval (plus 7-day pad)
    /// escapes `loadedRange` — the v2 policy, interval-based so a visible week can never
    /// straddle the window edge.
    func ensureLoaded(hub: CalendarHub) {
        guard hub.eventKitState == .some(true), let range = hub.loadedRange else { return }
        let cal = Calendar.current
        let interval: DateInterval = switch mode {
        case .week: CalendarMath.weekInterval(anchor: anchor, calendar: cal)
        case .day: DateInterval(start: cal.startOfDay(for: anchor), duration: 86_400)
        case .month: CalendarMath.monthGridInterval(anchor: anchor, calendar: cal)
        }
        let pad: TimeInterval = 7 * 86_400
        let needsLoad = !range.contains(interval.start.addingTimeInterval(-pad))
            || !range.contains(interval.end.addingTimeInterval(pad))
        if needsLoad {
            let a = anchor
            Task { await hub.refresh(anchor: a) }
        }
    }

    // MARK: - keyboard (shell forwards .onKeyPress here)

    func handleKey(_ press: KeyPress, hub: CalendarHub) -> KeyPress.Result {
        if press.key == .escape {
            guard selected != nil else { return .ignored }
            select(nil)
            return .handled
        }
        // Bare keys only past here (P3 audit LOW): ⌘/⇧/⌥-arrow chords belong to the system.
        guard press.modifiers.isEmpty else { return .ignored }
        if press.key == .leftArrow { page(-1, hub: hub); return .handled }
        if press.key == .rightArrow { page(1, hub: hub); return .handled }
        switch press.characters.lowercased() {
        case "t": goToday(hub: hub); return .handled
        case "w": setMode(.week, hub: hub); return .handled
        case "d": setMode(.day, hub: hub); return .handled
        case "m": setMode(.month, hub: hub); return .handled
        default: return .ignored
        }
    }

    // MARK: - derived display

    var toolbarTitle: String {
        let df = DateFormatter()
        df.dateFormat = "MMMM yyyy"
        return df.string(from: anchor)
    }
}
