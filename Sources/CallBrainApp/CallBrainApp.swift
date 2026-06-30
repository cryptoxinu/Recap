import SwiftUI
import AppKit

/// Without a packaged .app bundle, a SwiftPM SwiftUI executable launches as an accessory; promote it
/// to a regular foreground app (Dock icon + a real window) so it behaves like the shipped app will.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    // Closing the window leaves CallBrain alive in the menu bar (so background imports/transcriptions
    // keep running); the user quits explicitly via ⌘Q or the menu-bar Quit (Phase 6).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct CallBrainApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var env = AppEnvironment()

    var body: some Scene {
        WindowGroup(id: "main") {
            RootView()
                .environment(env)
                .frame(minWidth: 1040, minHeight: 700)
        }
        .windowToolbarStyle(.unified)

        MenuBarExtra("CallBrain", systemImage: "waveform.circle.fill") {
            MenuBarView().environment(env)
        }
        .menuBarExtraStyle(.menu)
    }
}

/// Menu-bar status + quick actions; shows live import/transcription progress even when the window is
/// closed, so the founder can see background jobs are still running (Phase 6).
struct MenuBarView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let active = env.importCoordinator.jobs.filter { $0.state == .running || $0.state == .queued }.count
        let open = env.openTaskCount()
        if active > 0 {
            Text("Importing \(active) item\(active == 1 ? "" : "s")…")
        } else {
            Text("CallBrain — \(env.meetingCount()) calls")
        }
        if open > 0 { Text("\(open) open action item\(open == 1 ? "" : "s")") }
        Divider()
        Button("Open CallBrain") { NSApp.activate(ignoringOtherApps: true); openWindow(id: "main") }
        Button("Quit CallBrain") { NSApp.terminate(nil) }
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
    case home, ask, meetings, tasks, imports, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: "Home"
        case .ask: "Ask AI"
        case .meetings: "Meetings"
        case .tasks: "Tasks"
        case .imports: "Import"
        case .settings: "Settings"
        }
    }
    var icon: String {
        switch self {
        case .home: "house"
        case .ask: "sparkles"
        case .meetings: "calendar.day.timeline.left"
        case .tasks: "checklist"
        case .imports: "tray.and.arrow.down"
        case .settings: "gearshape"
        }
    }
}

struct RootView: View {
    @Environment(AppEnvironment.self) private var env
    // Default tab; CALLBRAIN_TAB=<rawValue> opens straight to a tab (used for screenshot QA).
    @State private var selection: SidebarItem? = SidebarItem(
        rawValue: ProcessInfo.processInfo.environment["CALLBRAIN_TAB"] ?? "home") ?? .home
    @State private var showWelcome = !UserDefaults.standard.bool(forKey: WelcomeView.seenKey)
        && ProcessInfo.processInfo.environment["CALLBRAIN_TAB"] == nil   // skip during screenshot QA
    @AppStorage("callbrain.appearance") private var appearance = AppearanceMode.system.rawValue

    private var appearanceMode: AppearanceMode {
        // Screenshot QA: CALLBRAIN_APPEARANCE overrides the stored choice.
        if let f = ProcessInfo.processInfo.environment["CALLBRAIN_APPEARANCE"], let m = AppearanceMode(rawValue: f) { return m }
        return AppearanceMode(rawValue: appearance) ?? .system
    }

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selection) { item in
                Label(item.title, systemImage: item.icon).tag(item)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
            .navigationTitle("CallBrain")
            .safeAreaInset(edge: .bottom) { appearancePicker }
        } detail: {
            // CALLBRAIN_MEETING=<id> opens straight to a meeting detail (screenshot QA only).
            if let mid = ProcessInfo.processInfo.environment["CALLBRAIN_MEETING"], !mid.isEmpty {
                MeetingWorkspaceView(meetingID: mid)
            } else {
                switch selection ?? .home {
                case .home: HomeView()
                case .ask: AskView()
                case .meetings: MeetingsView()
                case .tasks: TasksView()
                case .imports: ImportView()
                case .settings: SettingsView()
                }
            }
        }
        .preferredColorScheme(appearanceMode.scheme)
        .task { NotificationManager.refresh(openTaskCount: env.openTaskCount()) }
        .sheet(isPresented: $showWelcome) { WelcomeView() }
    }

    /// Light / dark / system selector, pinned to the bottom of the sidebar.
    private var appearancePicker: some View {
        VStack(spacing: 0) {
            Divider()
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
