import SwiftUI
import CallBrainCore

/// Calendar v4 — Agenda moved to its own sidebar tab (`AgendaView`). This file now just holds
/// the shared row, used by the Agenda tab's Today/Upcoming lists.

/// One agenda row: right-aligned time column, calendar color bar, title + context line,
/// Recorded capsule. Click selects/opens; day-clamped time for continuation-day rows.
struct AgendaEventRow: View {
    let event: CalendarEvent
    /// The section's day — times are clamped to it (a continuation-day row reads 12:00 AM,
    /// not yesterday's start).
    var day: Date? = nil
    let link: Store.EventLink?
    var isSelected = false
    let onSelect: () -> Void
    let onUnlink: () -> Void

    private var color: Color { Color(hex: event.colorHex) ?? Theme.accent }
    private var isNow: Bool { !event.isAllDay && (event.start...max(event.start, event.end)).contains(Date()) }

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .center, spacing: 10) {
                Group {
                    if event.isAllDay {
                        Text("All day").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    } else {
                        Text(day.map { CalendarMath.displaySpan(event, on: $0).start } ?? event.start,
                             style: .time)
                            .font(.system(size: 12, weight: .medium)).monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 64, alignment: .trailing)
                RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: 3, height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title)
                        .font(.system(size: 13, weight: .medium)).lineLimit(1)
                        .foregroundStyle(.primary)
                    HStack(spacing: 6) {
                        Text(event.calendarName).font(.system(size: 11)).foregroundStyle(.tertiary)
                        if !event.attendees.isEmpty {
                            Text("· " + event.attendees.prefix(3).joined(separator: ", ")
                                 + (event.attendees.count > 3 ? " +\(event.attendees.count - 3)" : ""))
                                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                Spacer()
                if link != nil {
                    HStack(spacing: 4) {
                        Image(systemName: "waveform").font(.system(size: 9, weight: .bold))
                        Text("Recorded").font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().fill(Theme.accentSoft))
                }
            }
            .padding(.vertical, 8).padding(.horizontal, 10)
            .frame(minHeight: 44)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Theme.accentSoft : (isNow ? Theme.accent.opacity(0.06) : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cbHoverRow(radius: 8)
        .contextMenu {
            if link != nil { Button("Unlink call") { onUnlink() } }
        }
        .accessibilityLabel("\(event.title), \(event.isAllDay ? "all day" : event.start.formatted(date: .omitted, time: .shortened))\(link != nil ? ", recorded" : "")")
    }
}
