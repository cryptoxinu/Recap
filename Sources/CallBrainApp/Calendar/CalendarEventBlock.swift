import SwiftUI
import CallBrainCore

/// Calendar v3 — one time-positioned block in the week/day grid. Solid calendar-color fill,
/// auto-contrast text, text tiers by height, halo ring when selected, waveform when a
/// recorded call is linked. Past events fade (Notion's signature detail).
struct EventBlockView: View {
    let event: CalendarEvent
    /// Day-clamped span (final-gate MED): a 23:00→01:00 block on tomorrow's column sits at
    /// midnight — its label must say 12 AM, not the raw start.
    let displayStart: Date
    let displayEnd: Date
    let linked: Bool
    let isSelected: Bool
    let height: CGFloat
    let onSelect: () -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var hovered = false

    var body: some View {
        let style = EventPalette.style(hex: event.colorHex, scheme: scheme)
        let isPast = event.end < Date()
        Button(action: onSelect) {
            content(style)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: 5).fill(style.fill))
                .overlay {
                    if hovered || isSelected {
                        RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.08))
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if linked && height >= 26 {
                        Image(systemName: "waveform")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(style.text)
                            .padding(4)
                    }
                }
                .overlay {
                    if isSelected {
                        // Notion's double-border selection: ring in the calendar color with a
                        // 1pt gap of canvas showing through.
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(style.base, lineWidth: 2)
                            .padding(-3)
                    }
                }
                .opacity(isPast ? 0.55 : 1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hovered = inside
            if inside { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
        .animation(Theme.smooth, value: hovered)
        .animation(Theme.smooth, value: isSelected)
        .help(previewText)   // hover quick-preview: title · time · attendees · Recorded
        .accessibilityLabel("\(event.title), \(displayStart.formatted(date: .omitted, time: .shortened))\(linked ? ", recorded" : "")")
    }

    /// Rich hover tooltip (native, no popover jank): title, time range, attendees, status.
    private var previewText: String {
        var parts = [event.title]
        let t = "\(displayStart.formatted(date: .omitted, time: .shortened)) – \(displayEnd.formatted(date: .omitted, time: .shortened))"
        parts.append(t)
        if !event.attendees.isEmpty {
            parts.append(event.attendees.prefix(5).joined(separator: ", ")
                         + (event.attendees.count > 5 ? " +\(event.attendees.count - 5)" : ""))
        }
        if let loc = event.location, !loc.isEmpty { parts.append(loc) }
        if linked { parts.append("Recorded — click to open the transcript") }
        return parts.joined(separator: "\n")
    }

    /// Text tiers: micro (<26pt) title only · squat (26–44pt) one line · tall (≥44pt) two lines.
    @ViewBuilder private func content(_ style: EventPalette.Style) -> some View {
        if height < 26 {
            Text(event.title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(style.text)
                .lineLimit(1)
                .padding(.horizontal, 6).padding(.top, 1)
        } else if height < 44 {
            HStack(spacing: 4) {
                Text(event.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(style.text)
                    .lineLimit(1)
                Text(displayStart, style: .time)
                    .font(.system(size: 11))
                    .foregroundStyle(style.secondaryText)
                    .lineLimit(1)
                    .layoutPriority(-1)
            }
            .padding(.horizontal, 6).padding(.top, 4)
        } else {
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(style.text)
                    .lineLimit(height >= 64 ? 2 : 1)
                Text("\(displayStart.formatted(date: .omitted, time: .shortened)) – \(displayEnd.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 11))
                    .foregroundStyle(style.secondaryText)
                    .lineLimit(1)
            }
            .padding(.horizontal, 6).padding(.top, 4)
        }
    }
}

/// One pill in the pinned all-day row — same solid-fill language at 20pt.
struct AllDayChip: View {
    let event: CalendarEvent
    let linked: Bool
    let isSelected: Bool
    let onSelect: () -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var hovered = false

    var body: some View {
        let style = EventPalette.style(hex: event.colorHex, scheme: scheme)
        Button(action: onSelect) {
            HStack(spacing: 4) {
                Text(event.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(style.text)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if linked {
                    Image(systemName: "waveform")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(style.text)
                }
            }
            .padding(.horizontal, 6)
            .frame(height: 20)
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hovered = inside
            if inside { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
        .animation(Theme.smooth, value: hovered)
        .help(event.title)
    }
}
