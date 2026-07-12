import SwiftUI
import CallBrainCore

/// Identifiable request to open the editor via `.sheet(item:)`. Either edits an existing event
/// or creates a new one (optionally prefilled from a grid-slot double-click / NL quick-add).
struct EventEditorRequest: Identifiable {
    let id = UUID()
    var existing: CalendarEvent?
    var draft: EventDraft?
    static func new(_ draft: EventDraft? = nil) -> EventEditorRequest { .init(existing: nil, draft: draft) }
    static func edit(_ event: CalendarEvent) -> EventEditorRequest { .init(existing: event, draft: nil) }
}

/// Calendar v4 — create/edit an event, Notion-Calendar-clean. A big title field carrying the
/// chosen calendar's color, tidy time rows, and a prominent **account + calendar** picker so
/// it's obvious WHICH account the event lands on. Writes via EventWriter (off-main); delete
/// confirms first; Google-source events open read-only with a clear reason.
struct EventEditorView: View {
    let existing: CalendarEvent?
    var initialDraft: EventDraft?
    let onSaved: () -> Void

    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var start = Date()
    @State private var end = Date().addingTimeInterval(1800)
    @State private var isAllDay = false
    @State private var location = ""
    @State private var notes = ""
    @State private var attendees = ""
    @State private var calendarID: String?
    @State private var calendars: [EventWriter.WritableCalendar] = []
    @State private var saving = false
    @State private var errorText: String?
    @State private var confirmingDelete = false

    private var isEditing: Bool { existing != nil }
    // Read-only = directly-connected Google OR a non-writable EventKit calendar (holidays,
    // birthdays, subscribed feeds) — audit HIGH.
    private var isReadOnly: Bool { existing?.isReadOnly == true || existing?.sourceKind == .google }
    private var selectedCal: EventWriter.WritableCalendar? { calendars.first { $0.id == calendarID } }
    private var accentColor: Color { Color(hex: selectedCal?.colorHex) ?? Theme.accent }

    var body: some View {
        VStack(spacing: 0) {
            if isReadOnly { readOnlyBody } else { editBody }
        }
        .frame(width: 460)
        .frame(minHeight: isReadOnly ? 260 : 560)
        .background(Theme.cardFill)
        .interactiveDismissDisabled(saving)   // don't let a swipe-away race a commit (audit MED)
        .task { await bootstrap() }
    }

    // MARK: - edit body

    private var editBody: some View {
        VStack(spacing: 0) {
            // Title header with the calendar's color rail — big, primary, Notion-style.
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 3).fill(accentColor).frame(width: 5, height: 34)
                TextField("", text: $title, prompt: Text("Add title").foregroundStyle(.tertiary))
                    .textFieldStyle(.plain)
                    .font(.system(size: 22, weight: .semibold))
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary).frame(width: 24, height: 24)
                        .background(Circle().fill(Color.primary.opacity(0.06)))
                }
                .buttonStyle(.plain).disabled(saving)
            }
            .padding(.horizontal, 22).padding(.top, 22).padding(.bottom, 16)
            Divider()

            ScrollView {
                VStack(spacing: 2) {
                    row(icon: "clock") {
                        VStack(spacing: 10) {
                            Toggle("All day", isOn: $isAllDay.animation(Theme.smooth))
                                .font(.system(size: 14))
                            DatePicker("Starts", selection: $start,
                                       displayedComponents: isAllDay ? [.date] : [.date, .hourAndMinute])
                                .onChange(of: start) { _, n in if end <= n { end = n.addingTimeInterval(1800) } }
                            if !isAllDay {
                                DatePicker("Ends", selection: $end, in: start...,
                                           displayedComponents: [.date, .hourAndMinute])
                            }
                        }
                        .font(.system(size: 14))
                    }
                    Divider().padding(.leading, 52)
                    // The account + calendar picker — front and center.
                    row(icon: "calendar") { calendarPicker }
                    Divider().padding(.leading, 52)
                    row(icon: "mappin.and.ellipse") {
                        TextField("", text: $location, prompt: Text("Add location").foregroundStyle(.tertiary))
                            .textFieldStyle(.plain).font(.system(size: 14))
                    }
                    Divider().padding(.leading, 52)
                    row(icon: "person.2") {
                        VStack(alignment: .leading, spacing: 2) {
                            TextField("", text: $attendees, prompt: Text("Add people").foregroundStyle(.tertiary))
                                .textFieldStyle(.plain).font(.system(size: 14))
                                .disabled(isEditing)   // EventKit can't change attendees on an existing event
                            Text(isEditing
                                 ? "macOS won't let apps change an event's attendees — edit them in Calendar.app."
                                 : "Names are saved to the notes (macOS doesn't let apps send invites).")
                                .font(.system(size: 10)).foregroundStyle(.tertiary)
                        }
                    }
                    Divider().padding(.leading, 52)
                    row(icon: "text.alignleft") {
                        TextField("", text: $notes, prompt: Text("Add notes").foregroundStyle(.tertiary),
                                  axis: .vertical)
                            .textFieldStyle(.plain).font(.system(size: 14)).lineLimit(2...6)
                    }
                }
                .padding(.vertical, 6)
            }
            Divider()
            footer
        }
    }

    private func row<Content: View>(icon: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.system(size: 14)).foregroundStyle(.secondary)
                .frame(width: 24).padding(.top, 2)
            content()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22).padding(.vertical, 12)
    }

    /// Account-grouped calendar picker: a Menu whose label shows the chosen calendar's color +
    /// name + account, and whose items are sectioned by account.
    private var calendarPicker: some View {
        Menu {
            ForEach(accountsInOrder, id: \.self) { account in
                Section(account) {
                    ForEach(calendars.filter { $0.account == account }) { c in
                        Button { calendarID = c.id } label: {
                            Label {
                                Text(c.title + (c.isDefault ? " (default)" : ""))
                            } icon: {
                                Image(systemName: calendarID == c.id ? "checkmark" : "circle.fill")
                                    .foregroundStyle(Color(hex: c.colorHex) ?? Theme.accent)
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Circle().fill(accentColor).frame(width: 11, height: 11)
                VStack(alignment: .leading, spacing: 0) {
                    Text(selectedCal?.title ?? "Choose a calendar")
                        .font(.system(size: 14, weight: .medium)).foregroundStyle(.primary)
                    if let acct = selectedCal?.account {
                        Text(acct).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.hairline))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
    }

    private var accountsInOrder: [String] {
        var seen = Set<String>(); var out: [String] = []
        for c in calendars where seen.insert(c.account).inserted { out.append(c.account) }
        return out
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if isEditing {
                Button(role: .destructive) { confirmingDelete = true } label: {
                    Image(systemName: "trash")
                }
                .confirmationDialog("Delete this event?", isPresented: $confirmingDelete) {
                    Button("Delete event", role: .destructive) { Task { await performDelete() } }
                } message: { Text("This removes “\(title)” from your calendar. This can't be undone.") }
                .help("Delete event").disabled(saving)
            }
            if let errorText {
                Text(errorText).font(.system(size: 11)).foregroundStyle(Theme.warning).lineLimit(2)
            }
            Spacer()
            Button("Cancel") { dismiss() }.controlSize(.large).disabled(saving)
            Button(isEditing ? "Save" : "Add event") { Task { await performSave() } }
                .buttonStyle(.borderedProminent).tint(accentColor).controlSize(.large)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || saving)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 22).padding(.vertical, 16)
    }

    // MARK: - read-only (Google)

    private var readOnlyBody: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Event details").font(.headline)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            .padding(20)
            Divider()
            ContentUnavailableView {
                Label("Read-only event", systemImage: "lock")
            } description: {
                Text("“\(existing?.title ?? "This event")” is on a directly-connected Google "
                     + "calendar, which is read-only here. Edit it in Google Calendar, or add the "
                     + "account to macOS Calendar to edit it in Recap.")
            }
            .padding(.vertical, 12)
            Divider()
            HStack { Spacer(); Button("Done") { dismiss() }.controlSize(.large) }.padding(20)
        }
    }

    // MARK: - actions

    private func bootstrap() async {
        // Read-only sheet never writes — don't even touch EventKit (audit LOW).
        guard !isReadOnly else { return }
        calendars = await EventWriter.writableCalendars()
        if let e = existing {
            title = e.title; start = e.start; end = e.end; isAllDay = e.isAllDay
            location = e.location ?? ""
            notes = e.notes ?? ""   // as-is — no rewriting of external notes (final-audit)
            attendees = e.attendees.joined(separator: ", ")
            // Seed by the exact calendar IDENTIFIER (audit HIGH: title-only match could pick
            // the wrong account when two calendars share a name), title as fallback.
            calendarID = e.calendarID.flatMap { id in calendars.first(where: { $0.id == id })?.id }
                ?? calendars.first(where: { $0.title == e.calendarName })?.id
                ?? defaultCalendarID()
        } else if let d = initialDraft {
            title = d.title; start = d.start; end = d.end; isAllDay = d.isAllDay
            location = d.location ?? ""; notes = d.notes ?? ""
            attendees = d.attendees.joined(separator: ", ")
            calendarID = calendars.first(where: { $0.title == d.calendarName })?.id ?? defaultCalendarID()
        } else {
            calendarID = defaultCalendarID()
        }
    }

    private func defaultCalendarID() -> String? {
        calendars.first(where: \.isDefault)?.id ?? calendars.first?.id
    }

    private func draft() -> EventDraft {
        let people = attendees.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        // Pass the calendar IDENTIFIER (targetCalendar matches id OR title) so the exact
        // picked calendar is targeted even when two accounts share a title.
        return EventDraft(title: title.trimmingCharacters(in: .whitespaces),
                          start: start, end: end, isAllDay: isAllDay,
                          location: location.isEmpty ? nil : location,
                          notes: notes.isEmpty ? nil : notes,
                          attendees: people, calendarName: selectedCal?.id)
    }

    private func performSave() async {
        saving = true; errorText = nil
        do {
            if let e = existing { try await EventWriter.update(e, with: draft()) }
            else { try await EventWriter.create(draft()) }
            onSaved(); dismiss()
        } catch {
            errorText = error.localizedDescription; saving = false
        }
    }

    private func performDelete() async {
        guard let e = existing else { return }
        saving = true; errorText = nil
        do {
            try await EventWriter.delete(e)
            NotificationManager.cancelPrepReady(eventID: e.id)   // don't fire for a gone event
            // Drop the cached prep brief for the deleted event so it can't linger orphaned
            // (source-hashing covers edits, but a delete left the row forever) (audit E LOW).
            let store = env.store, eid = e.id
            await Task.detached { _ = try? store.deletePrep(eventID: eid) }.value
            onSaved(); dismiss()
        }
        catch { errorText = error.localizedDescription; saving = false }
    }
}
