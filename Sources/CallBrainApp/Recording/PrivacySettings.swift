import AppKit
import CoreGraphics

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

    /// Whether Screen Recording is authorized right now. ScreenCaptureKit needs this to capture the OTHER
    /// participants' audio ("Call audio"); without it we fall back to mic-only.
    static func screenRecordingAuthorized() -> Bool { CGPreflightScreenCaptureAccess() }

    /// Proactively pop the native "Allow Screen Recording" dialog when it isn't granted yet, so the user gets
    /// a one-click Allow instead of hunting through System Settings (the app previously just let
    /// ScreenCaptureKit fail silently). No-op once granted. Returns the current authorization status.
    @discardableResult
    static func requestScreenRecording() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        return CGRequestScreenCaptureAccess()
    }
}
