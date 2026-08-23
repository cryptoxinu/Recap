import Foundation

/// Which system-audio capture backend the recorder should use. Persisted under `defaultsKey`.
///
/// Two real backends exist behind this choice:
/// - ScreenCaptureKit (`.screenCapture`) — today's proven path; needs the heavier Screen Recording
///   grant but works everywhere including Bluetooth output.
/// - Core Audio process tap (`.coreAudioTap`) — lighter "Audio Recording" permission, no Screen
///   Recording nag; can miss the remote party on Bluetooth output, so we avoid it there.
///
/// `.auto` is the user-facing "recommended" choice. Its *effective* backend is decided by
/// `resolve(_:isBluetooth:tapAvailable:)` — a PURE function so it is fully unit-testable with no
/// Core Audio calls. See `autoPrefersTap` for the Phase B → Phase C gate.
public enum SystemAudioBackendKind: String, CaseIterable, Sendable {
    /// Recommended. In Phase B this resolves to `.screenCapture` (see `autoPrefersTap`); in Phase C it
    /// becomes tap-on-non-Bluetooth / SCKit-on-Bluetooth.
    case auto
    /// Force the Core Audio process tap (still falls back to SCKit on Bluetooth output — see `resolve`).
    case coreAudioTap
    /// Force ScreenCaptureKit — today's behavior, the safe fallback that works on any output.
    case screenCapture

    /// UserDefaults key the Settings picker binds to.
    public static let defaultsKey = "callbrain.systemAudioBackend"

    /// The raw persisted preference. Unset or unknown → `.auto` (the recommended choice). This is the
    /// stored *preference*, NOT the effective backend — always run it through `resolve` before use.
    public static func current(_ defaults: UserDefaults = .standard) -> SystemAudioBackendKind {
        SystemAudioBackendKind(rawValue: defaults.string(forKey: defaultsKey) ?? "") ?? .auto
    }

    // MARK: - Phase gate

    /// PHASE GATE — the single line that separates Phase B from Phase C.
    ///
    /// Phase B ships this `false`, so `.auto` (the default) resolves to `.screenCapture` — the proven
    /// ScreenCaptureKit recorder is byte-for-byte unchanged for everyone who hasn't explicitly opted
    /// into the tap. The tap is opt-in for founder dogfooding via the Settings picker.
    ///
    /// Phase C = flip this to `true` (ONE line, nothing else changes) so `.auto` becomes
    /// tap-on-non-Bluetooth / SCKit-on-Bluetooth. Do NOT flip until the tap is proven on a real call.
    public static let autoPrefersTap = false

    // MARK: - Pure decision logic (no hardware)

    /// Collapse a stored preference into the concrete backend to build.
    ///
    /// Pure: inject `isBluetooth` (default-output transport) + `tapAvailable` (macOS ≥ 14.4) so this is
    /// fully unit-testable without touching Core Audio.
    ///
    /// - `tapAvailable == false` (macOS < 14.4) → always `.screenCapture` (taps don't exist yet).
    /// - `.screenCapture` → `.screenCapture` (honor the explicit safe choice).
    /// - `.coreAudioTap` → `.coreAudioTap`, EXCEPT Bluetooth output → `.screenCapture`. A Bluetooth
    ///   output can make the tap miss the remote party, so we fall back to the safe path even when the
    ///   founder explicitly picked the tap — a recording that captures the call beats one that doesn't.
    /// - `.auto` → `.screenCapture` in Phase B (`autoPrefersTap == false`); in Phase C it mirrors the
    ///   `.coreAudioTap` Bluetooth-aware behavior.
    public static func resolve(_ kind: SystemAudioBackendKind,
                               isBluetooth: Bool,
                               tapAvailable: Bool) -> SystemAudioBackendKind {
        guard tapAvailable else { return .screenCapture }
        switch kind {
        case .screenCapture:
            return .screenCapture
        case .coreAudioTap:
            return isBluetooth ? .screenCapture : .coreAudioTap
        case .auto:
            guard autoPrefersTap else { return .screenCapture }   // Phase B: opt-in only.
            return isBluetooth ? .screenCapture : .coreAudioTap    // Phase C behavior.
        }
    }
}
