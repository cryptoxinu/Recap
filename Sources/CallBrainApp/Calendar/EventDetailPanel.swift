import SwiftUI
import CallBrainCore

/// Calendar v3 right detail panel (replaces every popover): event facts + the Recap
/// differentiator — the linked-call card that jumps straight into the transcript. The
/// link is resolved LIVE from hub.links so a background linker landing upgrades an open
/// panel from "no recording" to Recorded without re-selection.
struct EventDetailPanel: View {
    let event: CalendarEvent
    let hub: CalendarHub
    let onOpenCall: (String) -> Void
    var onEdit: (() -> Void)? = nil
    let onClose: () -> Void

    @Environment(AppEnvironment.self) private var env
    @Environment(\.colorScheme) private var scheme
    @State private var meeting: Store.MeetingRow?

    private var link: Store.EventLink? { hub.links[event.id] }
    private var color: Color { Color(hex: event.colorHex) ?? Theme.accent }
    private var isPast: Bool { event.end < Date() }
    private var joinURL: URL? { ConferenceLink.detect(in: event) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                titleBlock
                Text(timeLine)
                    .font(.system(size: 13)).monospacedDigit()
                    .foregroundStyle(.secondary)
                calendarChip
                if let joinURL { joinRow(joinURL) }
                if !isPast { recordRow }
                if let location = event.location?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !location.isEmpty, !isURLOnly(location) {
                    detailRow(icon: "mappin.and.ellipse", text: location)
                }
                if !event.attendees.isEmpty { attendeeList }
                if let notes = trimmedNotes {
                    Divider()
                    // NO .textSelection here — it caused a layout loop / beachball on
                    // composite views once already (chat-freeze postmortem 2026-07-01).
                    Text(notes)
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .lineLimit(8)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                linkedCallSection
                // Prep for a FUTURE call, right from the grid — the free context + Generate.
                if !isPast {
                    Divider()
                    Label("Prep", systemImage: "doc.text.magnifyingglass")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    PrepCard(event: event)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .padding(.top, 14)   // room for the close button
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay(alignment: .topTrailing) { closeButton }
        // Keyed on titlesRevision too (P3 audit MED): a rename while the panel is open must
        // refresh the meeting title/summary.
        .task(id: "\(event.id)|\(link?.meetingID ?? "")|\(hub.linksNeedRefresh)|\(env.titlesRevision)") {
            await loadMeeting()
        }
    }

    // MARK: - pieces

    private var titleBlock: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 4, height: 36)
            Text(event.title)
                .font(.system(size: 17, weight: .semibold))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            // Edit only writable EventKit events — not Google, holidays, birthdays, or
            // subscribed feeds (audit HIGH).
            if let onEdit, event.sourceKind == .eventKit, !event.isReadOnly {
                Button { onEdit() } label: { Image(systemName: "pencil") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Edit event")
                    .padding(.trailing, 24)   // clear the close button
            }
        }
    }

    /// Record THIS meeting, pre-linked — the resulting call auto-attaches to this event so it
    /// shows a Recorded badge and the transcript is one click away. Reflects live state so the
    /// button doesn't invite a second recording over a running one.
    @ViewBuilder private var recordRow: some View {
        let rec = env.recording
        // Only THIS event's own recording shows a live label; a recording of a different call
        // leaves the button as a plain "Record this meeting" (tapping just reopens the panel —
        // startRecordFlow won't clobber the running one). P3 audit LOW.
        let isThis = rec.linkedEventID == event.id && rec.phase != .idle
        Button {
            if rec.phase == .idle { env.startRecordFlow(presetTitle: event.title, eventID: event.id) }
            else { env.recordSheetShown = true }
        } label: {
            Label(isThis && rec.phase == .recording ? "Recording this call…"
                    : isThis && rec.phase == .processing ? "Transcribing…"
                    : "Record this meeting",
                  systemImage: isThis && rec.phase == .recording ? "waveform" : "record.circle")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(isThis && rec.phase == .recording ? Theme.danger : Theme.accent)
        .controlSize(.regular)
    }

    private var timeLine: String {
        let day = event.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        if event.isAllDay { return "\(day) · All day" }
        let range = "\(event.start.formatted(date: .omitted, time: .shortened)) – \(event.end.formatted(date: .omitted, time: .shortened))"
        return "\(day) · \(range)"
    }

    private var calendarChip: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 10, height: 10)
            Text(event.calendarName).font(.system(size: 12, weight: .medium)).lineLimit(1)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule().fill(Color.primary.opacity(0.05)))
    }

    @ViewBuilder private func joinRow(_ url: URL) -> some View {
        if isPast {
            detailRow(icon: "video", text: url.host ?? "Conference link")
        } else {
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                Label("Join call", systemImage: "video.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).tint(Theme.accent)
            .controlSize(.regular)
            .help(url.absoluteString)
        }
    }

    private func detailRow(icon: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(.tertiary)
                .frame(width: 14)
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private var attendeeList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(event.attendees.prefix(5), id: \.self) { name in
                HStack(spacing: 8) {
                    Circle().fill(Color.primary.opacity(0.08))
                        .frame(width: 24, height: 24)
                        .overlay(Text(initials(name))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary))
                    Text(name).font(.system(size: 12)).lineLimit(1)
                }
            }
            if event.attendees.count > 5 {
                Text("+\(event.attendees.count - 5) more")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                    .padding(.leading, 32)
            }
        }
    }

    @ViewBuilder private var linkedCallSection: some View {
        if let link {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Theme.accentSoft)
                        .frame(width: 32, height: 32)
                        .overlay(Image(systemName: "waveform")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.accent))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(meeting?.displayTitle ?? link.eventTitle)
                            .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        if let summary = meeting?.aiSummary, !summary.isEmpty {
                            Text(summary).font(.system(size: 12)).foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
                Button {
                    onOpenCall(link.meetingID)
                } label: {
                    Label("Open transcript", systemImage: "text.alignleft")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(Theme.accent)
                Button("Unlink") { hub.unlink(eventID: event.id) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
            }
            .cbCard(padding: 12)
        } else if isPast {
            Text("No recording linked to this event.")
                .font(.system(size: 12)).foregroundStyle(.tertiary)
        }
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.primary.opacity(0.06)))
        }
        .buttonStyle(.plain)
        .padding(10)
        .help("Close (Esc)")
        .accessibilityLabel("Close event details")
    }

    // MARK: - helpers

    /// Provider notes are HTML + Google conference boilerplate — show the human part only.
    private var trimmedNotes: String? { EventNotes.clean(event.notes) }

    private func isURLOnly(_ s: String) -> Bool {
        s.lowercased().hasPrefix("http") && !s.contains(" ")
    }

    private func initials(_ name: String) -> String {
        let parts = name.split(separator: " ")
        let first = parts.first?.first.map(String.init) ?? "?"
        let last = parts.count > 1 ? parts.last?.first.map(String.init) ?? "" : ""
        return (first + last).uppercased()
    }

    private func loadMeeting() async {
        guard let mid = link?.meetingID else { meeting = nil; return }
        meeting = nil   // never show the previous selection's meeting while loading
        let store = env.store
        let row = await Task.detached { try? store.meeting(id: mid) }.value
        // .task(id:) cancellation doesn't reach the detached child (P3 audit MED) — a stale
        // fetch resuming after the selection changed must not clobber the new panel.
        guard !Task.isCancelled else { return }
        meeting = row
    }
}
