import SwiftUI
import CallBrainCore

/// Calendar v3 left rail (Notion-style, quiet): mini month + calendar visibility list +
/// Google connect. The color square IS the visibility control — click a row to toggle.
struct CalendarLeftRail: View {
    let hub: CalendarHub
    let model: CalendarTabModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                MiniMonth(hub: hub, model: model)
                    .padding(.bottom, 10)
                sectionHeader("Calendars")
                if hub.calendarNames.isEmpty {
                    Text("None found").font(.system(size: 12)).foregroundStyle(.tertiary)
                        .padding(.horizontal, 8).padding(.top, 2)
                } else {
                    ForEach(hub.calendarNames, id: \.self) { name in
                        CalendarToggleRow(name: name, hub: hub)
                    }
                }
                googleSection
                Spacer(minLength: 12)
            }
            .padding(16)
        }
        .background(Theme.cardFill.opacity(0.35))
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .semibold)).kerning(0.6)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 8).padding(.top, 14).padding(.bottom, 4)
    }

    @ViewBuilder private var googleSection: some View {
        if hub.googleConfigured {
            VStack(alignment: .leading, spacing: 6) {
                // Always available (founder: "add gmail accountS") — each connect ADDS an
                // account; Settings → Calendars lists and disconnects them.
                Button {
                    Task { await hub.connectGoogle() }
                } label: {
                    Label(hub.googleAccounts.isEmpty ? "Connect Google Calendar…"
                                                     : "Add Google account…",
                          systemImage: "g.circle")
                        .font(.system(size: 12))
                }
                .buttonStyle(.link)
                .help("For Google accounts not added to macOS Calendar")
                if let status = hub.googleStatus {
                    Text(status).font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 8).padding(.top, 14)
        }
    }
}

/// One calendar row: 10pt color square (filled = visible, outlined = hidden), name, click
/// anywhere toggles.
private struct CalendarToggleRow: View {
    let name: String
    let hub: CalendarHub

    var body: some View {
        let color = Color(hex: hub.calendarColors[name]) ?? Theme.accent.opacity(0.7)
        let hidden = hub.isHidden(name)
        Button {
            withAnimation(Theme.smooth) { hub.setCalendar(name, hidden: !hidden) }
        } label: {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(hidden ? Color.clear : color)
                    .overlay(RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(color, lineWidth: hidden ? 1.5 : 0))
                    .frame(width: 10, height: 10)
                Text(name)
                    .font(.system(size: 12)).lineLimit(1)
                    .foregroundStyle(hidden ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cbHoverRow(radius: 6)
        .help(hidden ? "Show \(name)" : "Hide \(name)")
        .accessibilityLabel("\(name), \(hidden ? "hidden" : "shown")")
    }
}

/// Quiet Notion-style mini month: no event dots, hover-revealed chevrons, click navigates.
/// Pages independently of the main view; re-syncs whenever the model's anchor moves.
private struct MiniMonth: View {
    let hub: CalendarHub
    let model: CalendarTabModel
    @State private var pagedAnchor: Date?
    @State private var hovering = false

    private var cal: Calendar { .current }
    private var displayAnchor: Date { pagedAnchor ?? model.anchor }

    var body: some View {
        VStack(spacing: 8) {
            header
            weekdayLetters
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7),
                      spacing: 2) {
                ForEach(Array(gridDays.enumerated()), id: \.offset) { _, day in
                    dayCell(day)
                }
            }
        }
        .onHover { hovering = $0 }
        .onChange(of: TimeCode.ymd(model.anchor)) { pagedAnchor = nil }   // re-sync on navigation
    }

    private var header: some View {
        HStack {
            Text(monthTitle).font(.system(size: 12, weight: .semibold))
            Spacer()
            if hovering {
                Button { page(-1) } label: { Image(systemName: "chevron.left").font(.system(size: 9, weight: .semibold)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel("Previous month")
                Button { page(1) } label: { Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel("Next month")
            }
        }
        .padding(.horizontal, 4)
        .animation(.easeInOut(duration: 0.15), value: hovering)
        .frame(height: 18)
    }

    private var weekdayLetters: some View {
        HStack {
            let symbols = cal.veryShortStandaloneWeekdaySymbols
            ForEach(0..<7, id: \.self) { i in
                Text(symbols[(i + cal.firstWeekday - 1) % 7])
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder private func dayCell(_ day: Date?) -> some View {
        if let day {
            let ymd = TimeCode.ymd(day)
            let isSelected = ymd == model.selectedYMD
            let isToday = ymd == TimeCode.ymd(Date())
            Button {
                model.focus(day: day, hub: hub)
            } label: {
                Text("\(cal.component(.day, from: day))")
                    .font(.system(size: 11, weight: isToday ? .bold : .regular))
                    .foregroundStyle(isToday ? .white : (isSelected ? Theme.accent : Color.primary))
                    .frame(width: 26, height: 24)
                    .background(
                        Circle()
                            .fill(isToday ? Theme.accent : (isSelected ? Theme.accentSoft : .clear))
                            .frame(width: 20, height: 20)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            Color.clear.frame(width: 26, height: 24)
        }
    }

    private var monthTitle: String {
        let df = DateFormatter(); df.dateFormat = "MMMM yyyy"
        return df.string(from: displayAnchor)
    }

    private func page(_ delta: Int) {
        pagedAnchor = cal.date(byAdding: .month, value: delta, to: displayAnchor) ?? displayAnchor
    }

    private var gridDays: [Date?] {
        guard let interval = cal.dateInterval(of: .month, for: displayAnchor) else { return [] }
        let first = interval.start
        let weekdayOffset = (cal.component(.weekday, from: first) - cal.firstWeekday + 7) % 7
        let dayCount = cal.range(of: .day, in: .month, for: displayAnchor)?.count ?? 30
        return Array(repeating: nil, count: weekdayOffset)
            + (0..<dayCount).map { cal.date(byAdding: .day, value: $0, to: first) }
    }
}
