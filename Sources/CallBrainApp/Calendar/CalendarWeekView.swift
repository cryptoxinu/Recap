import SwiftUI
import CallBrainCore

/// Calendar v3 — the Notion centerpiece: hour-gutter time grid. Week passes 7 days, Day
/// passes 1. The grid chrome (hour lines, day separators) is ONE Canvas — never 168 cell
/// views; blocks are offset-positioned from DayEventLayout minutes. The now-line ticks
/// inside its own TimelineView so nothing else re-evaluates per minute.
struct CalendarWeekView: View {
    let hub: CalendarHub
    let model: CalendarTabModel
    let days: [Date]
    /// Double-click an empty slot → create at that time.
    var onCreateAt: ((Date) -> Void)? = nil
    /// Drag a block → move/resize; commit the new times.
    var onReschedule: ((CalendarEvent, Date, Date) -> Void)? = nil

    static let gutterWidth: CGFloat = 52
    static let hourHeight: CGFloat = 56
    static let gridHeight: CGFloat = 24 * hourHeight   // 1344
    static let snapMinutes = 15

    @State private var scrollPos = ScrollPosition()
    @State private var allDayExpanded = false
    /// In-flight drag: the event id, the vertical delta (points), and whether it's a resize.
    @State private var drag: (id: String, dy: CGFloat, resize: Bool)?

    private var todayYMD: String { TimeCode.ymd(Date()) }
    private var showsToday: Bool { days.contains { TimeCode.ymd($0) == todayYMD } }

    var body: some View {
        GeometryReader { geo in
            let colWidth = max(40, (geo.size.width - Self.gutterWidth) / CGFloat(max(days.count, 1)))
            VStack(spacing: 0) {
                WeekHeaderRow(days: days, model: model, hub: hub, colWidth: colWidth)
                Divider()
                allDayRow(colWidth: colWidth)
                ScrollView(.vertical) {
                    grid(colWidth: colWidth)
                        .frame(height: Self.gridHeight)
                }
                .scrollPosition($scrollPos)
                .scrollIndicators(.never)
                .task { scrollToStart(viewportHeight: geo.size.height, animated: false) }
                .onChange(of: model.scrollToNowRequest) {
                    scrollToStart(viewportHeight: geo.size.height, animated: true)
                }
            }
        }
    }

    // MARK: - all-day row

    @ViewBuilder private func allDayRow(colWidth: CGFloat) -> some View {
        let perDay: [[CalendarEvent]] = days.map { day in
            hub.events(onYMD: TimeCode.ymd(day)).filter(\.isAllDay)
        }
        if perDay.contains(where: { !$0.isEmpty }) {
            let maxCount = perDay.map(\.count).max() ?? 0
            let visibleRows = allDayExpanded ? maxCount : min(maxCount, 2)
            HStack(alignment: .top, spacing: 0) {
                // Clicking "all-day" toggles the expanded row — the only way to collapse it
                // again after "+N" expanded it (audit LOW).
                Button {
                    withAnimation(Theme.smooth) { if allDayExpanded { allDayExpanded = false } }
                } label: {
                    Text("all-day")
                        .font(.system(size: 9)).foregroundStyle(.tertiary)
                        .padding(.trailing, 8)
                        .frame(width: Self.gutterWidth, alignment: .trailing)
                        .padding(.top, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(allDayExpanded ? "Collapse all-day events" : "")
                .disabled(!allDayExpanded)
                ForEach(Array(days.enumerated()), id: \.offset) { i, _ in
                    VStack(spacing: 2) {
                        ForEach(perDay[i].prefix(visibleRows)) { e in
                            AllDayChip(event: e, linked: hub.links[e.id] != nil,
                                       isSelected: model.selected?.id == e.id,
                                       onSelect: { model.select(e) })
                        }
                        if !allDayExpanded && perDay[i].count > 2 {
                            Button {
                                withAnimation(Theme.smooth) { allDayExpanded = true }
                            } label: {
                                Text("+\(perDay[i].count - 2)")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 2)
                    .frame(width: colWidth, alignment: .top)
                }
            }
            .padding(.vertical, 3)
            Divider()
        }
    }

    // MARK: - the grid

    private func grid(colWidth: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            TimeGridCanvas(days: days, colWidth: colWidth)
            // Double-click an empty slot → create at that time (one transparent layer / column).
            if onCreateAt != nil {
                ForEach(Array(days.enumerated()), id: \.offset) { i, day in
                    createLayer(day: day, index: i, colWidth: colWidth)
                }
            }
            hourLabels
            ForEach(Array(days.enumerated()), id: \.offset) { i, day in
                dayColumn(day, index: i, colWidth: colWidth)
            }
            // Always mounted; today-membership is decided INSIDE the TimelineView from
            // context.date (audit MED: an outside gate goes stale at midnight — the line
            // stayed on yesterday's column until something else re-rendered).
            NowLineOverlay(days: days, colWidth: colWidth)
        }
    }

    private var hourLabels: some View {
        ForEach(1..<24, id: \.self) { h in
            Text(hourLabel(h))
                .font(.system(size: 10, weight: .medium)).monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: Self.gutterWidth - 8, alignment: .trailing)
                .offset(y: CGFloat(h) * Self.hourHeight - 6)
        }
    }

    /// Transparent per-column layer catching a double-click on empty space → create.
    private func createLayer(day: Date, index: Int, colWidth: CGFloat) -> some View {
        let colX = Self.gutterWidth + CGFloat(index) * colWidth
        return Color.clear
            .frame(width: colWidth, height: Self.gridHeight)
            .contentShape(Rectangle())
            .offset(x: colX)
            .gesture(SpatialTapGesture(count: 2).onEnded { g in
                onCreateAt?(timeAt(y: g.location.y, day: day))
            })
    }

    /// Snap a grid y-offset to a time on `day` — NEAREST 15 minutes (audit MED: flooring put
    /// a click near the next quarter into the prior slot).
    private func timeAt(y: CGFloat, day: Date) -> Date {
        let mins = Double(y / Self.hourHeight * 60)
        let snapped = min(max(0, Int((mins / Double(Self.snapMinutes)).rounded()) * Self.snapMinutes),
                          24 * 60 - Self.snapMinutes)
        return Calendar.current.date(bySettingHour: snapped / 60, minute: snapped % 60, second: 0, of: day) ?? day
    }

    @ViewBuilder private func dayColumn(_ day: Date, index: Int, colWidth: CGFloat) -> some View {
        // Pre-bucketed day read (final-gate LOW): buckets are intersection-aware since v3,
        // so this replaces an O(whole-window) scan per column per redraw.
        let events = hub.events(onYMD: TimeCode.ymd(day)).filter { !$0.isAllDay }
        let placed = DayEventLayout.place(events, on: day)
        let colX = Self.gutterWidth + CGFloat(index) * colWidth
        ForEach(placed) { p in
            let laneWidth = (colWidth - 4) * p.widthFraction
            let dragging = drag?.id == p.event.id
            let dy = dragging ? (drag?.dy ?? 0) : 0
            let resizing = dragging && (drag?.resize ?? false)
            // Clamp the dragged y to the grid so a block dragged past the bottom can't produce
            // a negative height (audit MED).
            let rawY = CGFloat(p.startMinute) / 60 * Self.hourHeight + (resizing ? 0 : dy)
            let y = min(max(0, rawY), Self.gridHeight - 17)
            let baseH = max(17, CGFloat(p.endMinute - p.startMinute) / 60 * Self.hourHeight - 2)
            let h = max(17, min(baseH + (resizing ? dy : 0), Self.gridHeight - y))
            let span = CalendarMath.displaySpan(p.event, on: day)
            // Multi-day/continuation slices are NOT draggable (audit HIGH: a delta from the
            // clamped slice would rewrite the whole event wrongly) — edit those in the sheet.
            let editable = p.event.sourceKind == .eventKit && !p.event.isReadOnly
                && onReschedule != nil && !span.continuesBefore && !span.continuesAfter
            EventBlockView(event: p.event,
                           displayStart: span.start, displayEnd: span.end,
                           linked: hub.links[p.event.id] != nil,
                           isSelected: model.selected?.id == p.event.id,
                           height: h,
                           onSelect: { model.select(p.event) })
                .frame(width: max(20, laneWidth - 2), height: h)
                .overlay(alignment: .bottom) {
                    if editable {   // resize handle
                        resizeHandle(event: p.event, day: day)
                    }
                }
                .opacity(dragging ? 0.85 : 1)
                .offset(x: colX + 2 + laneWidth * CGFloat(p.column) + (p.column > 0 ? 2 : 0), y: y)
                .zIndex(dragging ? 10 : 0)
                .gesture(editable ? moveGesture(event: p.event, day: day) : nil)
        }
    }

    /// Move the whole block by dragging its body (>8pt so a tap still selects). Computes the
    /// new time as WALL-CLOCK minutes on the same day (audit MED: raw-seconds delta drifts
    /// across a DST boundary; the grid renders wall-clock).
    private func moveGesture(event: CalendarEvent, day: Date) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .local)
            .onChanged { g in drag = (event.id, g.translation.height, false) }
            .onEnded { g in
                defer { drag = nil }
                let deltaMin = snappedMinutes(g.translation.height)
                guard deltaMin != 0 else { return }
                let cal = Calendar.current
                let durMin = Int(event.end.timeIntervalSince(event.start) / 60)
                let startMin = cal.component(.hour, from: event.start) * 60 + cal.component(.minute, from: event.start)
                let newStartMin = min(max(0, startMin + deltaMin), 24 * 60 - Self.snapMinutes)
                guard let newStart = cal.date(bySettingHour: newStartMin / 60, minute: newStartMin % 60,
                                              second: 0, of: event.start) else { return }
                let newEnd = cal.date(byAdding: .minute, value: durMin, to: newStart) ?? event.end
                onReschedule?(event, newStart, newEnd)
            }
    }

    /// A 7pt strip at the block bottom that resizes the END only (wall-clock minutes).
    private func resizeHandle(event: CalendarEvent, day: Date) -> some View {
        Rectangle().fill(Color.white.opacity(0.001)).frame(height: 7)
            .contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.resizeUpDown.set() } else { NSCursor.arrow.set() } }
            .gesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .local)
                    .onChanged { g in drag = (event.id, g.translation.height, true) }
                    .onEnded { g in
                        defer { drag = nil }
                        let deltaMin = snappedMinutes(g.translation.height)
                        guard deltaMin != 0 else { return }
                        let newEnd = Calendar.current.date(byAdding: .minute, value: deltaMin, to: event.end) ?? event.end
                        guard newEnd.timeIntervalSince(event.start) >= Double(Self.snapMinutes * 60) else { return }
                        onReschedule?(event, event.start, newEnd)
                    }
            )
    }

    /// Grid points → NEAREST 15 minutes (audit MED: truncation dropped a 29-min move to 15).
    private func snappedMinutes(_ dyPoints: CGFloat) -> Int {
        let rawMin = Double(dyPoints / Self.hourHeight * 60)
        return Int((rawMin / Double(Self.snapMinutes)).rounded()) * Self.snapMinutes
    }

    private func hourLabel(_ h: Int) -> String {
        let hour12 = h % 12 == 0 ? 12 : h % 12
        return "\(hour12) \(h < 12 ? "AM" : "PM")"
    }

    /// Open/Today target: now-line at 30% of the viewport when today is visible, else 8 AM.
    private func scrollToStart(viewportHeight: CGFloat, animated: Bool) {
        let targetY: CGFloat
        if showsToday {
            let now = Calendar.current.dateComponents([.hour, .minute], from: Date())
            let nowY = (CGFloat(now.hour ?? 8) + CGFloat(now.minute ?? 0) / 60) * Self.hourHeight
            targetY = max(0, nowY - viewportHeight * 0.3)
        } else {
            targetY = 8 * Self.hourHeight
        }
        if animated {
            withAnimation(Theme.smooth) { scrollPos.scrollTo(y: targetY) }
        } else {
            scrollPos.scrollTo(y: targetY)
        }
    }
}

// MARK: - day headers

/// Uppercase weekday + large numeral; today gets the accent circle. Click a header → Day view.
private struct WeekHeaderRow: View {
    let days: [Date]
    let model: CalendarTabModel
    let hub: CalendarHub
    let colWidth: CGFloat

    private var cal: Calendar { .current }

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: CalendarWeekView.gutterWidth, height: 44)
            ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                header(day)
            }
        }
    }

    @ViewBuilder private func header(_ day: Date) -> some View {
        let ymd = TimeCode.ymd(day)
        let isToday = ymd == TimeCode.ymd(Date())
        let isWeekend = cal.isDateInWeekend(day)
        Button {
            model.focus(day: day, hub: hub, switchTo: .day)
        } label: {
            HStack(spacing: 5) {
                Text(weekdayLabel(day).uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isToday ? AnyShapeStyle(Theme.accent)
                                     : (isWeekend ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary)))
                Text("\(cal.component(.day, from: day))")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(isToday ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(isToday ? Theme.accent : .clear))
                Spacer(minLength: 0)
            }
            .padding(.leading, 10)
            .frame(width: colWidth, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open \(MeetingsView.friendlyDate(ymd)) in Day view")
    }

    private func weekdayLabel(_ day: Date) -> String {
        let df = DateFormatter(); df.dateFormat = "EEE"
        return df.string(from: day)
    }
}

// MARK: - grid chrome (ONE Canvas)

private struct TimeGridCanvas: View {
    let days: [Date]
    let colWidth: CGFloat

    var body: some View {
        Canvas { ctx, size in
            let hairline = Color(nsColor: .separatorColor).opacity(0.7)
            let gutter = CalendarWeekView.gutterWidth
            // Hour lines
            for h in 0...24 {
                let y = CGFloat(h) * CalendarWeekView.hourHeight
                var line = Path()
                line.move(to: CGPoint(x: gutter, y: y))
                line.addLine(to: CGPoint(x: size.width, y: y))
                ctx.stroke(line, with: .color(hairline), lineWidth: 0.5)
            }
            // Day separators (including the gutter edge)
            for i in 0...days.count {
                let x = gutter + CGFloat(i) * colWidth
                var line = Path()
                line.move(to: CGPoint(x: x, y: 0))
                line.addLine(to: CGPoint(x: x, y: size.height))
                ctx.stroke(line, with: .color(hairline), lineWidth: 0.5)
            }
        }
        .frame(height: CalendarWeekView.gridHeight)
        .allowsHitTesting(false)
    }
}

// MARK: - now line

/// Red now-line: 2pt + dot on today's column, 0.25-opacity hairline across the rest, red
/// time chip in the gutter. `.everyMinute` — and ONLY this view re-evaluates on the tick.
private struct NowLineOverlay: View {
    let days: [Date]
    let colWidth: CGFloat

    var body: some View {
        TimelineView(.everyMinute) { context in
            let now = context.date
            let todayIndex = days.firstIndex { Calendar.current.isDate($0, inSameDayAs: now) }
            // Nothing renders unless the visible days contain today — decided per-tick so
            // midnight moves the line to the new column (or removes it) within a minute.
            if let todayIndex {
                let comps = Calendar.current.dateComponents([.hour, .minute], from: now)
                let y = (CGFloat(comps.hour ?? 0) + CGFloat(comps.minute ?? 0) / 60) * CalendarWeekView.hourHeight
                let red = Color(nsColor: .systemRed)
                ZStack(alignment: .topLeading) {
                    // Cross-week hairline
                    Rectangle()
                        .fill(red.opacity(0.25))
                        .frame(height: 1)
                        .padding(.leading, CalendarWeekView.gutterWidth)
                        .offset(y: y - 0.5)
                    // Today's emphatic line + dot
                    let x = CalendarWeekView.gutterWidth + CGFloat(todayIndex) * colWidth
                    Circle()
                        .fill(red)
                        .frame(width: 7, height: 7)
                        .offset(x: x - 3.5, y: y - 3.5)
                    Rectangle()
                        .fill(red)
                        .frame(width: colWidth, height: 2)
                        .offset(x: x, y: y - 1)
                    // Gutter time chip (knocks out the grid line behind it)
                    Text(now, style: .time)
                        .font(.system(size: 10, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(red)
                        .padding(.horizontal, 2)
                        .background(Rectangle().fill(.background))
                        .frame(width: CalendarWeekView.gutterWidth - 4, alignment: .trailing)
                        .offset(y: y - 6)
                }
                .allowsHitTesting(false)
            }
        }
    }
}
