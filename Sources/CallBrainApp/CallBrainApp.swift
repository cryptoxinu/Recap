import SwiftUI
import AppKit
import CallBrainCore

/// Without a packaged .app bundle, a SwiftPM SwiftUI executable launches as an accessory; promote it
/// to a regular foreground app (Dock icon + a real window) so it behaves like the shipped app will.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Register the `callbrain://` URL handler as early as possible so a cold-launch pairing deep link
    /// (the extension opens `callbrain://pair`) isn't missed.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleURLEvent(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    /// Handle `callbrain://pair` — one-click extension pairing. The extension opens this URL, which
    /// launches/focuses the app; we then open the loopback pairing window the extension polls.
    @objc func handleURLEvent(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: s), url.scheme?.lowercased() == "callbrain" else { return }
        let action = (url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).lowercased()
        guard action == "pair" else { return }
        // The env is created synchronously at launch; if this fires a hair early, retry briefly.
        // AppleEvents are delivered on the main thread, so it's safe to touch @MainActor state directly.
        func tryPair(_ attempt: Int) {
            MainActor.assumeIsolated {
                if let env = AppEnvironment.current { env.handlePairDeepLink() }
                else if attempt < 20 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { tryPair(attempt + 1) }
                }
            }
        }
        tryPair(0)
    }

    /// While the extension hasn't paired, re-open the pairing window every time the app comes to the
    /// front — so the deep link (which focuses the app) reliably leaves a window open for the extension
    /// to pair against, even if the GetURL event timing is imperfect.
    func applicationDidBecomeActive(_ notification: Notification) {
        MainActor.assumeIsolated { AppEnvironment.current?.openPairingWindowIfUnpaired() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        MainThreadWatchdog.shared.startIfEnabled()   // CALLBRAIN_WATCHDOG=1 → logs any main-thread stall
        // Brand the Dock/⌘-Tab icon (works for the dev run too, which has no .icns bundle).
        if let url = Bundle.module.url(forResource: "AppIcon", withExtension: "png"),
           let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
        NSApp.activate(ignoringOtherApps: true)
    }
    // Closing the window leaves Recap alive in the menu bar (so background imports/transcriptions
    // keep running); the user quits explicitly via ⌘Q or the menu-bar Quit (Phase 6).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        // Belt-and-suspenders (founder: nothing resident when the app isn't running): if a recording was
        // still active at quit, tell a running Ollama to evict the live model now. No-op if it's down.
        let model = UserDefaults.standard.string(forKey: "callbrain.localSummaryModel") ?? "qwen2.5:3b"
        OllamaLiveProvider.unloadSyncBestEffort(model: model)
        // Don't leave the plaintext pairing token on disk once we're quit (SME MED). The bridge is
        // rewritten on the next launch's server bind, so removing it here is safe. A hard `kill` can
        // skip this — the file is also backup-excluded + rewrite-on-bind to bound the exposure.
        NativeMessagingInstaller.removeBridge(applicationSupport: NativeMessagingInstaller.defaultApplicationSupport())
    }
}

@main
struct CallBrainApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var env = AppEnvironment()
    // Read the user's appearance choice here too so the SEPARATE scenes (Record window, Settings) honor a
    // forced light/dark — otherwise they resolve the dynamic tokens against the system appearance, not the
    // user's pick (P1+P2 audit: separate Window/Settings scenes don't inherit RootView's preferredColorScheme).
    @AppStorage("callbrain.appearance") private var appearance = AppearanceMode.system.rawValue
    private var appearanceScheme: ColorScheme? {
        if let f = ProcessInfo.processInfo.environment["CALLBRAIN_APPEARANCE"], let m = AppearanceMode(rawValue: f) { return m.scheme }
        return (AppearanceMode(rawValue: appearance) ?? .system).scheme
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            RootView()
                .environment(env)
                .frame(minWidth: 1040, minHeight: 700)
        }
        .windowToolbarStyle(.unified)
        .commands { AppCommands(env: env) }

        // The Record panel is a real RESIZABLE, movable window (Granola-style) — it can sit alongside the
        // call while you record, and stays open independent of the main window. Driven by the same
        // `env.recordSheetShown` signal every surface already flips (RootView opens it on change).
        Window("Record meeting", id: "record") {
            RecordView()
                .environment(env)
                .frame(minWidth: 460, minHeight: 460)
                .preferredColorScheme(appearanceScheme)   // honor the forced appearance in this separate window
        }
        .defaultSize(width: 940, height: 680)
        .windowResizability(.contentMinSize)
        .keyboardShortcut("r", modifiers: [.command, .shift])   // ⇧⌘R focuses the record window

        Settings {   // ⌘, — the native place for app settings (Task 7.2)
            SettingsView()
                .environment(env)
                .frame(minWidth: 640, minHeight: 520)
                .preferredColorScheme(appearanceScheme)   // honor the forced appearance in the Settings scene
        }

        MenuBarExtra("Recap", systemImage: "waveform.circle.fill") {
            MenuBarView().environment(env)
        }
        .menuBarExtraStyle(.menu)
    }
}

/// App-wide menu commands + keyboard shortcuts (Task 7.2) — the Mac-native contract: every core
/// action reachable from the keyboard, discoverable in the menu bar.
struct AppCommands: Commands {
    let env: AppEnvironment
    @Environment(\.openWindow) private var openWindow

    /// Run a command with the main window guaranteed visible + focused. The app stays alive in the
    /// menu bar after its window closes, so a command that only mutated `env` had no mounted RootView
    /// to consume it — the shortcut silently did nothing (audit G3 MED). Opens the window only if one
    /// isn't already up, so we never spawn a duplicate.
    private func route(_ action: @escaping () -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        if !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) {
            openWindow(id: "main")
        }
        action()
    }

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Chat") { route { env.selectedTab = .ask; env.askChat.newChat() } }
                .keyboardShortcut("n", modifiers: .command)
            Button("Record Meeting") { route { env.recordSheetShown = true } }
                .keyboardShortcut("r", modifiers: .command)
            Button("Import Files…") { route { env.selectedTab = .imports } }
                .keyboardShortcut("i", modifiers: [.command, .shift])
        }
        CommandMenu("Go") {
            Button("Search Everything") { route { env.paletteShown.toggle() } }
                .keyboardShortcut("k", modifiers: .command)
            Divider()
            Button("Home") { route { env.selectedTab = .home } }.keyboardShortcut("1", modifiers: .command)
            Button("Ask AI") { route { env.selectedTab = .ask } }.keyboardShortcut("2", modifiers: .command)
            Button("Meetings") { route { env.selectedTab = .meetings } }.keyboardShortcut("3", modifiers: .command)
            Button("Calendar") { route { env.selectedTab = .calendar } }.keyboardShortcut("4", modifiers: .command)
            Button("Agenda") { route { env.selectedTab = .agenda } }.keyboardShortcut("5", modifiers: .command)
            Button("Tasks") { route { env.selectedTab = .tasks } }.keyboardShortcut("6", modifiers: .command)
            Button("Import") { route { env.selectedTab = .imports } }.keyboardShortcut("7", modifiers: .command)
            Divider()
            Button("Focus Ask Composer") { route { env.selectedTab = .ask; env.composerFocusRequest &+= 1 } }
                .keyboardShortcut("l", modifiers: .command)
            Button("Find in Transcript") { route { env.findRequest &+= 1 } }
                .keyboardShortcut("f", modifiers: .command)
        }
    }
}

/// Menu-bar status + quick actions; shows live import/transcription progress even when the window is
/// closed, so the founder can see background jobs are still running (Phase 6).
struct MenuBarView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let active = env.importCoordinator.jobs.filter { $0.state == .running || $0.state == .queued }.count
        let open = env.openTaskCountCached          // cached — no synchronous COUNT read on the main thread
        if active > 0 {
            Text("Importing \(active) item\(active == 1 ? "" : "s")…")
        } else {
            Text("Recap — \(env.meetingCountCached) calls")
        }
        if open > 0 { Text("\(open) open action item\(open == 1 ? "" : "s")") }
        Divider()
        // Task 9.1 — quick capture from anywhere. ⌥⌘Space works app-wide while the menu extra
        // is installed (SwiftUI registers MenuBarExtra item shortcuts globally for the app).
        Button("Ask Recap…") {
            NSApp.activate(ignoringOtherApps: true); openWindow(id: "main")
            env.selectedTab = .ask; env.composerFocusRequest &+= 1
        }
        .keyboardShortcut(.space, modifiers: [.option, .command])
        Button("Paste Transcript from Clipboard") {
            guard let text = NSPasteboard.general.string(forType: .string),
                  text.trimmingCharacters(in: .whitespacesAndNewlines).count > 40 else { return }
            NSApp.activate(ignoringOtherApps: true); openWindow(id: "main")
            env.selectedTab = .imports
            Task { await env.importCoordinator.enqueuePaste(text) }
        }
        Button("Search Everything…") {
            NSApp.activate(ignoringOtherApps: true); openWindow(id: "main")
            env.paletteShown = true
        }
        Divider()
        switch env.recording.phase {
        case .recording:
            Button {
                Task { await env.recording.stop(env: env) }
            } label: { Label("Stop Recording (\(env.recording.elapsedString))", systemImage: "stop.fill") }
        case .processing:
            Text("Transcribing recording…")
        case .idle:
            Button("Record Meeting…") {
                NSApp.activate(ignoringOtherApps: true); openWindow(id: "main")
                env.recordSheetShown = true
            }
        }
        Divider()
        Button("Open Recap") { NSApp.activate(ignoringOtherApps: true); openWindow(id: "main") }
        Button("Quit Recap") { NSApp.terminate(nil) }
    }
}

/// Engine health, shrunk to a sidebar pill (Task 7.4): quiet green when fine, red with a
/// one-word fix when something the app depends on is down. Detail popover on click.
struct EngineStatusPill: View {
    @Environment(AppEnvironment.self) private var env
    @State private var status = SystemStatus()
    @State private var showDetail = false

    private var premiumOK: Bool { env.providerPrimary == .codex ? status.snap.codexOK : status.snap.claudeOK }
    private var degraded: Bool { status.snap.loaded && (!status.snap.ollamaOK || !premiumOK) }

    var body: some View {
        Button { showDetail = true } label: {
            HStack(spacing: 6) {
                Circle().fill(!status.snap.loaded ? Theme.textTertiary : degraded ? Theme.danger : Theme.success)
                    .frame(width: 7, height: 7)
                Text(label).font(.caption).foregroundStyle(degraded ? .primary : .secondary)
                Spacer()
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(degraded ? Theme.dangerSoft : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showDetail, arrowEdge: .trailing) { detail }
        .task { await status.refresh() }
    }

    private var label: String {
        guard status.snap.loaded else { return "Checking engine…" }
        if !status.snap.ollamaOK && !premiumOK { return "Engine offline" }
        if !status.snap.ollamaOK { return "Local AI off" }
        if !premiumOK { return "Premium AI missing" }
        return "All systems go"
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Engine status").font(.headline)
            line("Ollama (local models)", status.snap.ollamaOK,
                 status.snap.ollamaOK ? "running" : "not running")
            if !status.snap.ollamaOK {
                Button("Start local AI") {
                    Task.detached {
                        SystemStatus.startOllama()
                        try? await Task.sleep(for: .seconds(3))
                        await status.refresh()
                        await MainActor.run { env.drainPendingEmbeddings() }   // settle IOUs on recovery
                    }
                }
                .buttonStyle(.borderedProminent).controlSize(.small)
            } else {
                // In-app OFF switch (no more desktop scripts). Force-unloads the model + stops the server so
                // nothing stays resident. It auto-starts again the moment you record, so this is safe to use.
                Button("Turn off local AI") {
                    Task.detached {
                        SystemStatus.stopOllama()
                        await status.refresh()
                    }
                }
                .buttonStyle(.bordered).controlSize(.small)
                Text("Auto-starts when you record — safe to turn off.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            line("Premium · \(env.providerPrimary == .codex ? "Codex" : "Claude") CLI", premiumOK,
                 premiumOK ? "available" : "CLI not found")
            HStack {
                Spacer()
                Button { Task { await status.refresh() } } label: {
                    Label(status.checking ? "Checking…" : "Refresh", systemImage: "arrow.clockwise").font(.caption)
                }.buttonStyle(.plain).foregroundStyle(Theme.accent).disabled(status.checking)
            }
        }
        .padding(14).frame(width: 300, alignment: .leading)
    }

    private func line(_ title: String, _ ok: Bool, _ detail: String) -> some View {
        HStack(spacing: 8) {
            Circle().fill(ok ? Theme.success : Theme.danger).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// The prominent "search everything" affordance under Record — makes the ⌘K palette discoverable (it was
/// keyboard-only before) so the fast jump-to-anything spine is one click away.
struct SidebarSearchButton: View {
    @Environment(AppEnvironment.self) private var env
    var body: some View {
        Button { env.paletteShown = true } label: {
            HStack(spacing: Space.s) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                Text("Search everything").font(.cbCallout).foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 0)
                Text("⌘K").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.hairline))
            }
            .padding(.horizontal, Space.s + 2).padding(.vertical, Space.s - 1)
            .background(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).strokeBorder(Theme.hairline))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Search everything (⌘K)")
        .padding(.horizontal, 10).padding(.bottom, 8)
    }
}

/// User-chosen window appearance (sidebar selector). `system` follows macOS; the others pin it.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var scheme: ColorScheme? { self == .light ? .light : self == .dark ? .dark : nil }
    var icon: String { self == .system ? "circle.lefthalf.filled" : self == .light ? "sun.max.fill" : "moon.fill" }
    var label: String { rawValue.capitalized }
}

enum SidebarItem: String, CaseIterable, Identifiable {
    case home, ask, meetings, calendar, agenda, tasks, people, imports, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: "Home"
        case .ask: "Ask AI"
        case .meetings: "Meetings"
        case .calendar: "Calendar"
        case .agenda: "Agenda"
        case .tasks: "Tasks"
        case .people: "People"
        case .imports: "Import"
        case .settings: "Settings"
        }
    }
    var icon: String {
        switch self {
        case .home: "house"
        case .ask: CBIcon.ask                          // was "sparkles" (AI slop)
        case .meetings: "waveform.circle"              // the archive of recorded calls
        case .calendar: "calendar"
        case .agenda: "calendar.day.timeline.left"     // today's timeline (distinct from Calendar); was "sparkles.rectangle.stack"
        case .tasks: "checklist"
        case .people: "person.2"
        case .imports: "tray.and.arrow.down"
        case .settings: "gearshape"
        }
    }
}

struct RootView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.openWindow) private var openWindow
    // Tab selection lives in AppEnvironment (env.selectedTab) so any view can switch tabs — e.g. a call's
    // "go full screen" jumps to the Ask tab. Seeded from CALLBRAIN_TAB there.
    @State private var showWelcome = !UserDefaults.standard.bool(forKey: WelcomeView.seenKey)
        && ProcessInfo.processInfo.environment["CALLBRAIN_TAB"] == nil   // skip during screenshot QA
    @AppStorage("callbrain.appearance") private var appearance = AppearanceMode.system.rawValue

    private var appearanceMode: AppearanceMode {
        // Screenshot QA: CALLBRAIN_APPEARANCE overrides the stored choice.
        if let f = ProcessInfo.processInfo.environment["CALLBRAIN_APPEARANCE"], let m = AppearanceMode(rawValue: f) { return m }
        return AppearanceMode(rawValue: appearance) ?? .system
    }

    var body: some View {
        @Bindable var env = env
        return NavigationSplitView {
            // Settings lives in the native ⌘, scene now (Task 7.2) — not a sidebar tab.
            List(SidebarItem.allCases.filter { $0 != .settings }, selection: $env.selectedTab) { item in
                Label(item.title, systemImage: item.icon)
                    .badge(badgeCount(item))   // P2 sweep: glanceable counts
                    .tag(item)
            }
            .listStyle(.sidebar)
            .tint(Theme.accent)   // brand-violet selection + focus ring, not the system accent
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
            .navigationTitle("Recap")
            .safeAreaInset(edge: .top) {
                VStack(spacing: 6) { RecordButton(); SidebarSearchButton() }.background(.bar)
            }
            .safeAreaInset(edge: .bottom) { appearancePicker }
        } detail: {
            detailContent   // instant tab switch (native macOS behavior — no heavy cross-fade rebuild)
                .background(Theme.bg)   // calm base so the surface/elevation ladder reads correctly both modes
                .overlay(alignment: .top) {   // persistent "you're recording" bar (survives sheet dismiss)
                    if env.recording.phase != .idle {
                        RecordingBar().transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .animation(Theme.springy, value: env.recording.phase)   // slide the bar in/out, don't snap
        }
        .preferredColorScheme(appearanceMode.scheme)
        // Any surface flipping `recordSheetShown` opens the resizable Record WINDOW. Reset the flag
        // IMMEDIATELY so it's edge-triggered: a repeat request (window already open) is a fresh
        // false→true edge that re-fires and focuses the window (audit MED — level-trigger lost re-opens).
        .onChange(of: env.recordSheetShown) { _, shown in
            if shown { openWindow(id: "record"); env.recordSheetShown = false }
        }
        .onChange(of: env.calendarHub.eventsRevision) { env.autoRecorder.reschedule(env: env) }
        .onChange(of: env.calendarHub.linksNeedRefresh) { env.autoRecorder.reschedule(env: env) }
        .task {
            // Drain a record request that was flipped BEFORE this RootView mounted — e.g. a menu-bar
            // "Record" while the main window was closed, where `.onChange` couldn't have fired yet
            // (audit HIGH: RootView was the only opener).
            if env.recordSheetShown { openWindow(id: "record"); env.recordSheetShown = false }
            if ProcessInfo.processInfo.environment["CALLBRAIN_RECORD"] == "1" { env.recordSheetShown = true }
            // Auto-record needs the calendar loaded even if the user never opens Calendar/Agenda
            // (P3 audit MED). Load first, THEN arm — the eventsRevision bump also re-arms.
            if env.autoRecorder.isEnabled { await env.calendarHub.refresh() }
            env.autoRecorder.reschedule(env: env)   // arm opt-in auto-record for the next linked meeting
            NotificationManager.refresh(openTaskCount: env.openTaskCount())
            // Task 9.1 — REAL global hotkey (Carbon), not a menu-item shortcut (gate MED).
            GlobalHotkey.install { [weak env] in
                guard let env else { return }
                NSApp.activate(ignoringOtherApps: true)
                env.selectedTab = .ask
                env.composerFocusRequest &+= 1
            }
        }
        .sheet(isPresented: $showWelcome) { WelcomeView() }
        .overlay {   // ⌘K palette floats over EVERYTHING (Task 7.1)
            if env.paletteShown { CommandPalette().transition(.opacity) }
        }
        .animation(Theme.quick, value: env.paletteShown)   // fade in/out, don't pop
        .onDisappear { env.paletteShown = false }   // app outlives its window — don't strand the overlay
        // P2 sweep: drop transcripts/recordings on ANY tab — imports queue and the tab jumps.
        .dropDestination(for: URL.self) { urls, _ in
            let importable = ImportCoordinator.importable(urls)
            guard !importable.isEmpty else { return false }
            env.selectedTab = .imports
            Task { await env.importCoordinator.enqueueFiles(importable) }
            return true
        }
    }

    @ViewBuilder private var detailContent: some View {
        // CALLBRAIN_MEETING=<id> opens straight to a meeting detail (screenshot QA only).
        if let mid = ProcessInfo.processInfo.environment["CALLBRAIN_MEETING"], !mid.isEmpty {
            MeetingWorkspaceView(meetingID: mid)
        } else {
            switch env.selectedTab ?? .home {
            case .home: HomeView(onNavigate: { env.selectedTab = $0 })
            case .ask: AskView()
            case .meetings: MeetingsView()
            case .calendar: CalendarView()
            case .agenda: AgendaView()
            case .tasks: TasksView()
            case .people: PeopleView()
            case .imports: ImportView()
            case .settings: HomeView(onNavigate: { env.selectedTab = $0 })   // Settings → ⌘, scene (7.2)
            }
        }
    }

    /// Sidebar badges (P2 sweep): open tasks on Tasks; needs-review imports on Import.
    private func badgeCount(_ item: SidebarItem) -> Int {
        switch item {
        case .tasks: env.openTaskCountCached
        case .imports: env.importCoordinator.jobs.filter { $0.state == .needsReview }.count
        default: 0
        }
    }

    /// Light / dark / system selector + Settings, pinned to the bottom of the sidebar.
    /// Settings also lives in the app menu (⌘,) — the visible row exists because the
    /// founder looked for it in the sidebar and found nothing (2026-07-02).
    private var appearancePicker: some View {
        VStack(spacing: 0) {
            Divider()
            EngineStatusPill()
                .padding(.horizontal, 10).padding(.top, 8)
            SettingsLink {
                Label("Settings", systemImage: "gearshape")
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .cbHoverRow(radius: 6)
            .help("Settings (⌘,)")
            .padding(.horizontal, 10).padding(.top, 6)
            Picker("Appearance", selection: $appearance) {
                ForEach(AppearanceMode.allCases) { mode in
                    Label(mode.label, systemImage: mode.icon).tag(mode.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("Window appearance")
            .padding(.horizontal, 10).padding(.vertical, 8)
        }
        .background(.bar)
    }
}
