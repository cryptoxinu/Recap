import AppKit

/// Deep-links to the exact macOS Privacy & Security pane for a recording permission, so a denied grant is
/// one tap to fix instead of "go dig through System Settings" (Phase 6 — TCC re-grant friction). After a
/// re-signed reinstall a grant can be reset; this makes recovering it trivial.
enum PrivacySettings {
    enum Kind {
        case microphone, screenRecording
        var settingsURL: URL {
            switch self {
            // The stable Privacy anchors macOS honors for a direct jump to the right list.
            case .microphone:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
            case .screenRecording:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
            }
        }
        /// One-line, plain-language label for the button.
        var buttonTitle: String {
            switch self {
            case .microphone: return "Open Microphone settings"
            case .screenRecording: return "Open Screen Recording settings"
            }
        }
    }

    /// Open the relevant Privacy pane. Falls back to the top-level Privacy & Security pane if the deep
    /// link is ever rejected by a future macOS.
    static func open(_ kind: Kind) {
        if !NSWorkspace.shared.open(kind.settingsURL) {
            if let fallback = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
                NSWorkspace.shared.open(fallback)
            }
        }
    }
}
