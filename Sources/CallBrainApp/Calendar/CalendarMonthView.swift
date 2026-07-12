import SwiftUI
import CallBrainCore

/// Calendar v3 month board — full-bleed weeks grid, solid-fill event chips (same language as
/// the week blocks), click a chip → detail panel, double-click a day → Day view of that date.
struct CalendarMonthView: View {
    let hub: CalendarHub
    let model: CalendarTabModel

    private var cal: Calendar { .current }

    var body: some View {
        VStack(spacing: 0) {
            weekdayHeader
            Divider()
            GeometryReader { geo in
                let weeks = gridWeeks
                let rowH = max(92, geo.size.height / CGFloat(max(weeks.count, 1)))
                VStack(spacing: 0) {
                    ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                        HStack(spacing: 0) {
                            ForEach(Array(week.enumerated()), id: \.offset) { _, day in
                                MonthDayCell(day: day, hub: hub, model: model)
                                    .frame(maxWidth: .infinity, minHeight: rowH, maxHeight: .infinity)
                                    .overlay(alignment: .trailing) { Divider() }
                            }
                        }
                        .overlay(alignment: .bottom) { Divider() }
                    }
                }
            }
        }
    }

    private var weekdayHeader: some View {
        HStack(spacing: 0) {
            let symbols = cal.shortStandaloneWeekdaySymbols
            ForEach(0..<7, id: \.self) { i in
                Text(symbols[(i + cal.firstWeekday - 1) % 7].uppercased())
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 8)
                    .padding(.vertical, 6)
            }
        }
        .background(.bar)
    }

    /// Full weeks covering the anchor month — adjacent-month days included (dimmed).
    private var gridWeeks: [[Date]] {
        guard let monthInterval = cal.dateInterval(of: .month, for: model.anchor),
              let firstWeek = cal.dateInterval(of: .weekOfYear, for: monthInterval.start) else { return [] }
        var weeks: [[Date]] = []
        var cursor = firstWeek.start
        repeat {
            weeks.append((0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: cursor) })
            cursor = cal.date(byAdding: .day, value: 7, to: cursor) ?? monthInterval.end
        } while cursor < monthInterval.end
        return weeks
    }
}

private struct MonthDayCell: View {
    let day: Date
    let hub: CalendarHub
    let model: CalendarTabModel

    private var cal: Calendar { .current }
    private var ymd: String { TimeCode.ymd(day) }
    private var inMonth: Bool { cal.isDate(day, equalTo: model.anchor, toGranularity: .month) }
    private var isToday: Bool { ymd == TimeCode.ymd(Date()) }

    var body: some View {
        let events = hub.events(onYMD: ymd)
        VStack(alignment: .leading, spacing: 2) {
            Text("\(cal.component(.day, from: day))")
                .font(.system(size: 13, weight: isToday ? .bold : .medium))
                .foregroundStyle(isToday ? AnyShapeStyle(.white)
                                 : (inMonth ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary)))
                .frame(width: 22, height: 22)
                .background(Circle().fill(isToday ? Theme.accent : .clear))
                .padding(.leading, 4).padding(.top, 4)

            let visible = Array(events.prefix(3))
            ForEach(visible) { e in
                MonthEventChip(event: e, day: day,
                               linked: hub.links[e.id] != nil, dimmed: !inMonth,
                               isSelected: model.selected?.id == e.id,
                               onSelect: { model.select(e) })
            }
            if events.count > 3 {
                Button {
                    model.focus(day: day, hub: hub, switchTo: .day)
                } label: {
                    Text("+\(events.count - 3) more")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.plain)
                .cbHoverRow(radius: 4)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(ymd == model.selectedYMD ? Theme.accent.opacity(0.06) : .clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.focus(day: day, hub: hub, switchTo: .day) }
        // Single click = selection ONLY (never re-anchors — P3 audit MED: re-anchoring on an
        // adjacent-month cell moved the grid under a double-click's second click).
        .onTapGesture { model.selectDay(day) }
        .accessibilityLabel("\(ymd), \(events.count) events")
    }
}

/// Month chip — the week block's solid-fill language at 18pt.
private struct MonthEventChip: View {
    let event: CalendarEvent
    let day: Date
    let linked: Bool
    var dimmed = false
    var isSelected = false
    let onSelect: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var hovered = false

    var body: some View {
        let style = EventPalette.style(hex: event.colorHex, scheme: scheme)
        let isPast = event.end < Date()
        // Day-clamped label (final-gate MED): a continuation day shows midnight, not the
        // raw start time from yesterday.
        let span = CalendarMath.displaySpan(event, on: day)
        Button(action: onSelect) {
            HStack(spacing: 4) {
                if !event.isAllDay {
                    Text(span.start, format: .dateTime.hour(.defaultDigits(amPM: .omitted)).minute())
                        .font(.system(size: 10)).monospacedDigit()
                        .foregroundStyle(style.secondaryText)
                }
                Text(event.title)
                    .font(.system(size: 11, weight: .medium)).lineLimit(1)
                    .foregroundStyle(style.text)
                Spacer(minLength: 0)
                if linked {
                    Image(systemName: "waveform")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(style.text)
                }
            }
            .padding(.horizontal, 6)
            .frame(height: 18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 4).fill(style.fill))
            .overlay {
                if hovered || isSelected {
                    RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.08))
                }
            }
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(style.base, lineWidth: 2)
                        .padding(-2)
                }
            }
            .padding(.horizontal, 4)
            .opacity(dimmed ? 0.4 : (isPast ? 0.55 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0; if $0 { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() } }
        .animation(Theme.smooth, value: hovered)
    }
}
