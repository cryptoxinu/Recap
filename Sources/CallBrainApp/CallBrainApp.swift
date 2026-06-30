import SwiftUI
import AppKit

/// Without a packaged .app bundle, a SwiftPM SwiftUI executable launches as an accessory; promote it
/// to a regular foreground app (Dock icon + a real window) so it behaves like the shipped app will.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct CallBrainApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var env = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(env)
                .frame(minWidth: 1040, minHeight: 700)
        }
        .windowToolbarStyle(.unified)
    }
}

enum SidebarItem: String, CaseIterable, Identifiable {
    case home, ask, meetings, imports, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: "Home"
        case .ask: "Ask AI"
        case .meetings: "Meetings"
        case .imports: "Import"
        case .settings: "Settings"
        }
    }
    var icon: String {
        switch self {
        case .home: "house"
        case .ask: "sparkles"
        case .meetings: "calendar.day.timeline.left"
        case .imports: "tray.and.arrow.down"
        case .settings: "gearshape"
        }
    }
}

struct RootView: View {
    // Default tab; CALLBRAIN_TAB=<rawValue> opens straight to a tab (used for screenshot QA).
    @State private var selection: SidebarItem? = SidebarItem(
        rawValue: ProcessInfo.processInfo.environment["CALLBRAIN_TAB"] ?? "home") ?? .home

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selection) { item in
                Label(item.title, systemImage: item.icon).tag(item)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
            .navigationTitle("CallBrain")
        } detail: {
            // CALLBRAIN_MEETING=<id> opens straight to a meeting detail (screenshot QA only).
            if let mid = ProcessInfo.processInfo.environment["CALLBRAIN_MEETING"], !mid.isEmpty {
                MeetingDetailView(meetingID: mid)
            } else {
                switch selection ?? .home {
                case .home: HomeView()
                case .ask: AskView()
                case .meetings: MeetingsView()
                case .imports: ImportView()
                case .settings: SettingsView()
                }
            }
        }
    }
}
