import SwiftUI
import CallBrainCore

/// Calendar v4 — Agenda is its own sidebar tab and the daily command center. It leads with a
/// **Prep for today** section (each of today's calls gets an AI prep card — the next one
/// auto-preps), then **Upcoming** grouped by day (prep on tap), then **Recently recorded** to
/// close the loop back into transcripts.
struct AgendaView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var hub: CalendarHub?
    @State private var recent: [Store.MeetingRow] = []

    var body: some View {
        Group {
            if let hub { content(hub) }
            else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .navigationTitle("Agenda")
        .task {
            let h = env.calendarHub
            hub = h
            await h.probe()
            if h.eventKitState == .some(true), h.loadedRange == nil { await h.refresh() }
            // Learn the founder's team domains from the loaded calendar so attendee research can tell
            // teammates from external guests (best-effort, cached).
            TeamDomains.updateDerived(from: h.events)
            await loadRecent()
        }
    }

    @ViewBuilder private func content(_ hub: CalendarHub) -> some View {
        switch hub.eventKitState {
        case .some(.some(true)):
            granted(hub)
        case .some(.some(false)):
            ContentUnavailableView("Calendar access is off", systemImage: "calendar.badge.exclamationmark",
                description: Text("Turn it on in System Settings → Privacy & Security → Calendars."))
        case .some(.none):
            ContentUnavailableView {
                Label("Connect your calendars", systemImage: "calendar.badge.plus")
            } description: {
                Text("Open the Calendar tab to connect — your agenda and call-prep appear here.")
            } actions: {
                Button("Open Calendar") { env.selectedTab = .calendar }.buttonStyle(.borderedProminent)
            }
        default:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func granted(_ hub: CalendarHub) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                prepForToday(hub)
                upcomingSections(hub)
                recentlyRecorded()
            }
            .padding(.horizontal, 24).padding(.vertical, 16)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: hub.linksNeedRefresh) { Task { await hub.refreshLinks() } }
    }

    // MARK: - prep for today

    @ViewBuilder private func prepForToday(_ hub: CalendarHub) -> some View {
        let today = TimeCode.ymd(Date())
        let now = Date()
        // Today's timed calls that haven't ended — the ones worth prepping for.
        let calls = hub.events(onYMD: today).filter { !$0.isAllDay && $0.end > now }
        // Auto-prep the next call that hasn't STARTED yet (not one already in progress).
        let nextID = calls.first(where: { $0.start > now })?.id
        Section {
            if calls.isEmpty {
                Text("No more calls today.")
                    .font(.cbBody).foregroundStyle(Theme.textSecondary)
                    .padding(.vertical, Space.s).padding(.horizontal, Space.xs)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(calls) { e in
                        VStack(alignment: .leading, spacing: 8) {
                            eventHeader(e, hub: hub)
                            PrepCard(event: e, autoGenerate: e.id == nextID)
                        }
                    }
                }
                .padding(.top, 4)
            }
        } header: {
            header("Prep for today", accent: true)
        }
    }

    private func eventHeader(_ e: CalendarEvent, hub: CalendarHub) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(hex: e.colorHex) ?? Theme.accent).frame(width: 4, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(e.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Text(timeAndPeople(e)).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let url = ConferenceLink.detect(in: e), e.end > Date() {
                Button { NSWorkspace.shared.open(url) } label: {
                    Label("Join", systemImage: "video.fill").font(.system(size: 12))
                }
                .buttonStyle(.bordered).controlSize(.small).tint(Theme.accent)
            }
        }
    }

    private func timeAndPeople(_ e: CalendarEvent) -> String {
        let t = e.start.formatted(date: .omitted, time: .shortened)
        guard !e.attendees.isEmpty else { return t }
        let who = e.attendees.prefix(3).joined(separator: ", ")
            + (e.attendees.count > 3 ? " +\(e.attendees.count - 3)" : "")
        return "\(t) · \(who)"
    }

    // MARK: - upcoming (lazy prep per row)

    @ViewBuilder private func upcomingSections(_ hub: CalendarHub) -> some View {
        let groups = CalendarMath.upcomingByDay(events: hub.events, now: Date())
        // QA (screenshot/smoke): CALLBRAIN_PREP_DEMO expands + generates the FIRST upcoming
        // call so a live grounded brief can be verified without a mouse.
        let demoID = ProcessInfo.processInfo.environment["CALLBRAIN_PREP_DEMO"] == "1"
            ? groups.flatMap(\.events).first(where: { !$0.attendees.isEmpty })?.id : nil
        ForEach(groups, id: \.ymd) { group in
            Section {
                ForEach(Array(group.events.enumerated()), id: \.element.id) { i, e in
                    UpcomingRow(event: e, day: CalendarMath.date(fromYMD: group.ymd),
                                link: hub.links[e.id], autoDemo: e.id == demoID,
                                onOpen: { open(e, hub: hub) },
                                onUnlink: { hub.unlink(eventID: e.id) })
                    if i < group.events.count - 1 { Divider().padding(.leading, 10) }
                }
            } header: {
                header(MeetingsView.friendlyDate(group.ymd), accent: false)
            }
        }
    }

    // MARK: - recently recorded

    @ViewBuilder private func recentlyRecorded() -> some View {
        if !recent.isEmpty {
            Section {
                ForEach(Array(recent.enumerated()), id: \.element.id) { i, m in
                    Button { env.openMeeting(m.id) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "waveform").font(.system(size: 11, weight: .bold))
                                .foregroundStyle(Theme.accent).frame(width: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(m.displayTitle).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                if let s = m.aiSummary, !s.isEmpty {
                                    Text(s).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer()
                            Text(MeetingsView.friendlyDate(m.date))
                                .font(.system(size: 11)).foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 8).padding(.horizontal, 10)
                        .frame(minHeight: 40).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).cbHoverRow(radius: 8)
                    if i < recent.count - 1 { Divider().padding(.leading, 10) }
                }
            } header: {
                header("Recently recorded", accent: false)
            }
        }
    }

    private func loadRecent() async {
        let store = env.store
        let rows = await Task.detached { (try? store.recentMeetings(limit: 6)) ?? [] }.value
        recent = rows
    }

    // MARK: - helpers

    private func header(_ title: String, accent: Bool) -> some View {
        Text(title)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(accent ? Theme.accent : Theme.textPrimary)
            .padding(.top, Space.xl - 2).padding(.bottom, Space.s).padding(.horizontal, Space.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.bg)
    }

    private func open(_ e: CalendarEvent, hub: CalendarHub) {
        if let link = hub.links[e.id] { env.openMeeting(link.meetingID) }
        else { env.selectedTab = .calendar }
    }
}

/// An upcoming-events row that reveals its prep card inline on tap (lazy — the AI only runs
/// when the founder opens it).
private struct UpcomingRow: View {
    let event: CalendarEvent
    let day: Date?
    let link: Store.EventLink?
    var autoDemo = false
    let onOpen: () -> Void
    var onUnlink: () -> Void = {}
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                AgendaEventRow(event: event, day: day, link: link,
                               onSelect: { withAnimation(Theme.smooth) { expanded.toggle() } },
                               onUnlink: onUnlink)
                    .layoutPriority(1)
                Button { withAnimation(Theme.smooth) { expanded.toggle() } } label: {
                    Image(systemName: expanded ? "chevron.up" : "doc.text.magnifyingglass")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(expanded ? Color.secondary : Theme.accent)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(expanded ? Color.primary.opacity(0.06) : Theme.accentSoft))
                }
                .buttonStyle(.plain)
                .help(expanded ? "Hide prep" : "Prep for this call")
                .padding(.trailing, 6)
            }
            if expanded {
                PrepCard(event: event, autoGenerate: autoDemo)
                    .padding(.leading, 74)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .task { if autoDemo { expanded = true } }
    }
}
