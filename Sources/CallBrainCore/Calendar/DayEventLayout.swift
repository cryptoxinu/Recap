import Foundation

/// Calendar v3 — the week-view overlap layout (interval partitioning, Notion/Google
/// semantics). Pure and geometry-free: positions are minutes from local midnight plus
/// (column, columnCount) within an overlap CLUSTER; the view maps minutes → points.
/// Clusters are independent — a lone 7 AM event keeps full width beside a 9 AM pileup.
public enum DayEventLayout {

    public struct Placed: Sendable, Equatable, Identifiable {
        public let event: CalendarEvent
        public let column: Int          // 0-based within its overlap cluster
        public let columnCount: Int     // shared by every event in the cluster
        public let startMinute: Int     // minutes from local midnight, clamped 0...1440
        public let endMinute: Int       // clamped; always > startMinute
        public var id: String { event.id }
        public var xFraction: Double { Double(column) / Double(columnCount) }
        public var widthFraction: Double { 1.0 / Double(columnCount) }
    }

    /// Timed-event layout for ONE day column. All-day events are excluded (the caller renders
    /// those in the pinned all-day row). Deterministic for identical input: ties break by
    /// (start asc, end desc, id asc), so longer events anchor the left column.
    public static func place(_ events: [CalendarEvent], on day: Date,
                             calendar: Calendar = .current,
                             minSlotMinutes: Int = 15) -> [Placed] {
        let dayStart = calendar.startOfDay(for: day)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return [] }

        // Wall-clock minute of day (hour*60+minute) so blocks align with the hour labels even
        // on DST-transition days; the grid is a fixed 24h canvas.
        func minuteOfDay(_ d: Date) -> Int {
            let c = calendar.dateComponents([.hour, .minute], from: d)
            return (c.hour ?? 0) * 60 + (c.minute ?? 0)
        }

        struct Item { let event: CalendarEvent; let s: Int; let e: Int }
        var items: [Item] = []
        for ev in events where !ev.isAllDay {
            // Intersects the day: starts before day-end AND ends after day-start (a
            // zero-duration event "ends" at its own start, which still counts inside the day).
            guard ev.start < dayEnd, ev.end > dayStart || (ev.start == ev.end && ev.start >= dayStart)
            else { continue }
            let s = ev.start < dayStart ? 0 : min(minuteOfDay(ev.start), 1439)
            var e = ev.end >= dayEnd ? 1440 : minuteOfDay(ev.end)
            // Fall-back DST (audit MED, both rounds): when the offset decreases across the
            // event, wall-clock spans read collapsed (1:00→1:00) or shrunken (1:30→1:45 is 75
            // real minutes). Restore real duration for SHORT events; long events keep
            // wall-clock END alignment — a 25-hour day can't render both on a 24-hour grid.
            let realMin = Int(ev.end.timeIntervalSince(ev.start) / 60)
            if ev.start >= dayStart, realMin > 0, realMin <= 120, e - s < realMin,
               calendar.timeZone.secondsFromGMT(for: ev.end)
                   < calendar.timeZone.secondsFromGMT(for: ev.start) {
                e = min(s + realMin, 1440)
            }
            // Inflate to the minimum slot for BOTH collision and rendering — two 5-minute
            // events 10 minutes apart genuinely collide on screen, so they must column-split.
            e = max(e, min(s + minSlotMinutes, 1440))
            items.append(Item(event: ev, s: s, e: e))
        }

        items.sort { a, b in
            if a.s != b.s { return a.s < b.s }
            if a.e != b.e { return a.e > b.e }
            return a.event.id < b.event.id
        }

        var out: [Placed] = []
        var columns: [Int] = []                        // per-column last end within the cluster
        var pending: [(item: Item, column: Int)] = []
        var clusterMaxEnd = 0

        func closeCluster() {
            let count = max(columns.count, 1)
            for p in pending {
                out.append(Placed(event: p.item.event, column: p.column, columnCount: count,
                                  startMinute: p.item.s, endMinute: p.item.e))
            }
            pending.removeAll(); columns.removeAll()
        }

        for item in items {
            // Touching (end == next start) does NOT overlap → back-to-back stays full width.
            if !pending.isEmpty && item.s >= clusterMaxEnd { closeCluster() }
            let column: Int
            if let free = columns.firstIndex(where: { $0 <= item.s }) {
                columns[free] = item.e; column = free   // reuse the freed column
            } else {
                columns.append(item.e); column = columns.count - 1
            }
            pending.append((item, column))
            clusterMaxEnd = max(clusterMaxEnd, item.e)
        }
        closeCluster()
        return out
    }
}
