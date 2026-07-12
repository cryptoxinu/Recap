import SwiftUI
import CallBrainCore

/// Calendar tab v3 (founder: "rip off Notion Calendar") — shell: toolbar, permission gating,
/// the rail / canvas / detail-panel HStack, and keyboard routing. Same type name as v2 so the
/// RootView mount (`case .calendar: CalendarView()`) is untouched.
struct CalendarView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var hub: CalendarHub?
    @State private var model = CalendarTabModel()
    @AppStorage("callbrain.calendar.railCollapsed") private var railCollapsed = false
    @FocusState private var calendarFocused: Bool
    // v4 event editor: nil = closed; the box distinguishes create (nil existing) from edit.
    @State private var editor: EventEditorRequest?
    // Serial chain so successive drags commit in order (audit MED).
    @State private var rescheduleChain: Task<Void, Never>?

    var body: some View {
        Group {
            if let hub {
                content(hub)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Calendar")
        .toolbar { toolbarContent }
        .sheet(item: $editor) { req in
            EventEditorView(existing: req.existing, initialDraft: req.draft) {
                if let hub { Task { await hub.refresh(anchor: model.anchor) } }
            }
        }
        .task {
            let h = env.calendarHub
            hub = h
            await h.probe()
            await h.probeGoogle()
            if h.eventKitState == .some(true) { await h.refresh() }
            // QA deep-link (smoke/screenshots): open the detail panel on a deterministic event.
            if ProcessInfo.processInfo.environment["CALLBRAIN_CAL_SELECT"] == "linked",
               let e = h.events.first(where: { h.links[$0.id] != nil }) ?? h.events.first {
                model.select(e)
            }
            // QA self-test: create + delete a throwaway event to prove the write round-trip
            // (writes ~2s to the default calendar, then removes it). Logs to /tmp.
            if ProcessInfo.processInfo.environment["CALLBRAIN_WRITE_SELFTEST"] != nil {
                await runWriteSelfTest()
            }
            // QA (screenshot): open the New-event editor.
            if ProcessInfo.processInfo.environment["CALLBRAIN_NEW_EVENT"] != nil {
                editor = .new(newEventDraft())
            }
        }
    }

    // MARK: - toolbar (Notion-quiet: chevrons, title, small Today, menu view switcher)

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            if let hub, hub.eventKitState == .some(true) {
                Button {
                    withAnimation(Theme.smooth) { railCollapsed.toggle() }
                } label: { Image(systemName: "sidebar.left") }
                    .help(railCollapsed ? "Show calendars" : "Hide calendars")
                    .accessibilityLabel("Toggle calendar list")
                Button { model.page(-1, hub: hub) } label: { Image(systemName: "chevron.left") }
                    .help("Previous").accessibilityLabel("Previous")
                Text(model.toolbarTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .frame(minWidth: 130)
                    .contentTransition(.opacity)
                    .animation(Theme.smooth, value: model.toolbarTitle)
                Button { model.page(1, hub: hub) } label: { Image(systemName: "chevron.right") }
                    .help("Next").accessibilityLabel("Next")
                Button("Today") { model.goToday(hub: hub) }
                    .controlSize(.small)
                    .help("Jump to today (T)")
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if let hub, hub.eventKitState == .some(true) {
                // v4: an inline segmented pill (M | W | D) replaces the old `.menu` Picker,
                // whose popover rendered detached/floating near the top of the screen
                // (founder screenshot). Agenda is now its own sidebar tab, so it's gone here.
                Picker("View", selection: Binding(get: { model.mode },
                                                  set: { model.setMode($0, hub: hub) })) {
                    ForEach(CalendarTabModel.Mode.allCases) { m in
                        Text(m.title).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 190)
                .help("Month (M) · Week (W) · Day (D)")

                Button { editor = .new(newEventDraft()) } label: { Image(systemName: "plus") }
                    .help("New event (N)")
                    .accessibilityLabel("New event")
            }
        }
    }

    /// QA-only: prove EventWriter create/delete round-trips through the app's TCC grant.
    private func runWriteSelfTest() async {
        let path = "/tmp/cb-write-selftest.log"
        func log(_ s: String) {
            let line = s + "\n"
            if let fh = FileHandle(forWritingAtPath: path) {
                fh.seekToEndOfFile(); fh.write(Data(line.utf8)); try? fh.close()
            } else { try? line.data(using: .utf8)?.write(to: URL(fileURLWithPath: path)) }
        }
        let marker = "Recap write self-test"
        let now = Date()
        // Pre-sweep any stragglers a prior crashed run may have orphaned (audit MED).
        await EventWriter.sweepByTitle(marker, near: now)
        let draft = EventDraft(title: marker, start: now.addingTimeInterval(3600),
                               end: now.addingTimeInterval(5400), notes: "safe to delete")
        do {
            let id = try await EventWriter.create(draft)
            log("CREATE ok id=\(id)")
            let stable = id.replacingOccurrences(of: "eventKit|", with: "")
            let probe = CalendarEvent(stableID: stable, sourceKind: .eventKit, calendarName: "",
                                      title: draft.title, start: draft.start, end: draft.end,
                                      attendees: [], isAllDay: false)
            try await EventWriter.delete(probe)
            log("DELETE ok — round-trip complete")
        } catch { log("FAILED: \(error.localizedDescription)") }
        // Post-sweep guarantees no residue even if delete raced (audit MED).
        await EventWriter.sweepByTitle(marker, near: now)
    }

    /// A blank draft anchored to a sensible time: next hour on the selected/anchor day.
    private func newEventDraft() -> EventDraft {
        let cal = Calendar.current
        let base = CalendarMath.date(fromYMD: model.selectedYMD) ?? model.anchor
        let hour = cal.component(.hour, from: Date())
        let start = cal.date(bySettingHour: min(hour + 1, 23), minute: 0, second: 0, of: base) ?? base
        return EventDraft(title: "", start: start, end: start.addingTimeInterval(1800))
    }

    // MARK: - permission states

    @ViewBuilder private func content(_ hub: CalendarHub) -> some View {
        switch hub.eventKitState {
        case .some(.some(true)):
            granted(hub)
        case .some(.some(false)):
            ContentUnavailableView {
                Label("Calendar access is off", systemImage: "calendar.badge.exclamationmark")
            } description: {
                Text("Turn it on in System Settings → Privacy & Security → Calendars, then come back.")
            } actions: {
                Button("Open Privacy Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                }
                Button("Check Again") {
                    Task { await hub.probe(); if hub.eventKitState == .some(true) { await hub.refresh() } }
                }
            }
        case .some(.none):
            ContentUnavailableView {
                Label("Connect your calendars", systemImage: "calendar.badge.plus")
            } description: {
                Text("Recap reads your macOS calendars — including Google, iCloud, and Exchange "
                     + "accounts already in Calendar.app — to show your meetings and link them to "
                     + "call recordings. Everything stays on this Mac.")
            } actions: {
                Button("Connect Calendars") { Task { await hub.connectEventKit() } }
                    .buttonStyle(.borderedProminent)
            }
        default:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - the three-pane layout

    private func granted(_ hub: CalendarHub) -> some View {
        GeometryReader { geo in
            // Audit HIGH: at the window minimum with the panel open, rail+panel+grid don't
            // fit — the rail yields automatically (the toolbar toggle still works when
            // space returns; the stored preference is untouched).
            let panelWidth: CGFloat = model.selected != nil ? 340 : 0
            let railFits = geo.size.width - panelWidth - 240 >= 480
            let showRail = !railCollapsed && railFits
            HStack(spacing: 0) {
                if showRail {
                    CalendarLeftRail(hub: hub, model: model)
                        .frame(width: 240)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    Divider()
                }
                VStack(spacing: 0) {
                    HStack {
                        QuickAddField(onDraft: { editor = .new($0) })
                        Spacer()
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    Divider()
                    mainContent(hub)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { model.select(nil) }   // click-away closes the panel
                if let selected = model.selected {
                    Divider()
                    EventDetailPanel(event: selected, hub: hub,
                                     onOpenCall: { env.openMeeting($0) },
                                     onEdit: { editor = .edit(selected) },
                                     onClose: { model.select(nil) })
                        .frame(width: 340)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(Theme.springy, value: model.selected == nil)
            .animation(Theme.smooth, value: showRail)
        }
        .focusable()
        .focusEffectDisabled()
        .focused($calendarFocused)
        .onKeyPress(phases: .down) { press in
            // 'n' = new event (shell state, not model) — handle before delegating.
            if press.modifiers.isEmpty, press.characters.lowercased() == "n" {
                editor = .new(newEventDraft()); return .handled
            }
            return model.handleKey(press, hub: hub)
        }
        .task { calendarFocused = true }
        .onChange(of: model.mode) { calendarFocused = true }   // reclaim after toolbar picker
        .onChange(of: hub.linksNeedRefresh) { Task { await hub.refreshLinks() } }
        .onChange(of: hub.eventsRevision) { model.reconcileSelection(hub: hub) }
    }

    @ViewBuilder private func mainContent(_ hub: CalendarHub) -> some View {
        switch model.mode {
        case .month:
            CalendarMonthView(hub: hub, model: model)
        case .week:
            CalendarWeekView(hub: hub, model: model,
                             days: CalendarMath.weekDays(anchor: model.anchor),
                             onCreateAt: { editor = .new(EventDraft(title: "", start: $0, end: $0.addingTimeInterval(1800))) },
                             onReschedule: { e, s, en in reschedule(e, s, en, hub: hub) })
        case .day:
            CalendarWeekView(hub: hub, model: model, days: [model.anchor],
                             onCreateAt: { editor = .new(EventDraft(title: "", start: $0, end: $0.addingTimeInterval(1800))) },
                             onReschedule: { e, s, en in reschedule(e, s, en, hub: hub) })
        }
    }

    private func reschedule(_ e: CalendarEvent, _ start: Date, _ end: Date, hub: CalendarHub) {
        // Serialize writes (audit MED: rapid drags could let an earlier EventKit write land
        // after a later one) — chain each reschedule after the prior completes.
        let prior = rescheduleChain
        rescheduleChain = Task {
            await prior?.value
            do {
                try await EventWriter.reschedule(e, start: start, end: end)
                // The old prep-ready notification was timed to the old start — drop it; the
                // next Agenda view reschedules it for the new time (final-audit MED).
                NotificationManager.cancelPrepReady(eventID: e.id)
            } catch { /* failed write → the refresh below snaps the block back */ }
            await hub.refresh(anchor: model.anchor)
        }
    }
}
