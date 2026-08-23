import Foundation
import AVFoundation
import CallBrainAppCore

/// Builds the system-audio backend the recorder should use, from the persisted preference plus live
/// hardware facts (macOS version + default-output transport). The actual decision is the PURE
/// `SystemAudioBackendKind.resolve(_:isBluetooth:tapAvailable:)` in CallBrainAppCore — this factory
/// only gathers the hardware inputs and constructs the chosen concrete backend.
///
/// PHASE B DEFAULT-SAFETY: `.auto` (the shipped default) resolves to `.screenCapture`, so this returns
/// today's `SystemAudioCapture` for everyone who hasn't explicitly picked the tap in Settings — the
/// working recorder is byte-for-byte unchanged. The tap is built ONLY when the founder has explicitly
/// set `.coreAudioTap` (and isn't on Bluetooth output). Phase C is a one-line flip of
/// `SystemAudioBackendKind.autoPrefersTap`; nothing here changes.
enum SystemAudioBackendFactory {

    /// Construct the backend for the current preference. Always returns a working backend — resolving
    /// to the tap on a machine without tap support (macOS < 14.4) falls back to `SystemAudioCapture`.
    static func make(target: AVAudioFormat,
                     onState: @escaping @Sendable (SystemAudioCaptureState) -> Void,
                     onSamples: @escaping @Sendable ([Int16], UInt64) -> Void) -> SystemAudioBackend {
        switch resolve(SystemAudioBackendKind.current()) {
        case .coreAudioTap:
            if #available(macOS 14.4, *) {
                return CoreAudioTapCapture(target: target, onState: onState, onSamples: onSamples)
            }
            return SystemAudioCapture(target: target, onState: onState, onSamples: onSamples)
        case .auto, .screenCapture:
            return SystemAudioCapture(target: target, onState: onState, onSamples: onSamples)
        }
    }

    /// Collapse the stored preference into a concrete backend, reading the two hardware facts the pure
    /// resolver needs. Exposed so the RecordView permission hint can say the right thing (tap → "system
    /// audio recording"; SCKit → "screen recording").
    static func resolve(_ kind: SystemAudioBackendKind) -> SystemAudioBackendKind {
        var tapAvailable = false
        var isBluetooth = false
        if #available(macOS 14.4, *) {
            tapAvailable = true
            isBluetooth = AudioDeviceQuery.isDefaultOutputBluetooth()
        }
        return SystemAudioBackendKind.resolve(kind, isBluetooth: isBluetooth, tapAvailable: tapAvailable)
    }
}
