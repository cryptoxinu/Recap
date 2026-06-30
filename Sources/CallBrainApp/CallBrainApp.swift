import SwiftUI

@main
struct CallBrainApp: App {
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
    @State private var selection: SidebarItem? = .ask

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selection) { item in
                Label(item.title, systemImage: item.icon).tag(item)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
            .navigationTitle("CallBrain")
        } detail: {
            switch selection ?? .ask {
            case .home: HomeView()
            case .ask: AskView()
            case .meetings: MeetingsView()
            case .imports: ImportView()
            case .settings: SettingsView()
            }
        }
    }
}
