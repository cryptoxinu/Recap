import Foundation
import CoreAudio

/// Small, dependency-free reads against the Core Audio HAL that the tap backend needs:
/// the current default *output* device UID (the aggregate's main sub-device) and whether that
/// output is Bluetooth (where the tap can miss the remote party, so the selector prefers SCKit).
///
/// Every read is a single synchronous property fetch — cheap, non-blocking, and done once at start
/// (and again on a default-output-change), never per audio buffer.
enum AudioDeviceQuery {

    /// Any Core Audio HAL error, surfaced with the failing step + OSStatus for logs.
    struct QueryError: Error, CustomStringConvertible {
        let step: String
        let status: OSStatus
        var description: String { "AudioDeviceQuery.\(step) failed (OSStatus \(status))" }
    }

    /// The `AudioObjectID` of the current default *system output* device (the speakers/headset the
    /// user hears). Throws if the HAL has no default output (e.g. a headless machine).
    static func defaultOutputDeviceID() throws -> AudioObjectID {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != AudioObjectID(kAudioObjectUnknown) else {
            throw QueryError(step: "defaultOutputDeviceID", status: status)
        }
        return deviceID
    }

    /// The UID (a stable `CFString`) of the default output device — used as the aggregate's main
    /// sub-device so the aggregate tracks the real output.
    static func defaultOutputUID() throws -> String {
        let deviceID = try defaultOutputDeviceID()
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        // Core Audio returns a +1-retained CFStringRef here — read it as `Unmanaged` and take the
        // retained value so ARC balances it correctly (a plain `var uid: CFString` would over-release).
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &uid)
        guard status == noErr, let value = uid?.takeRetainedValue() else {
            throw QueryError(step: "defaultOutputUID", status: status)
        }
        return value as String
    }

    /// Whether the default output device is Bluetooth (classic or LE). On a best-effort read failure
    /// we return `false` (assume wired) — the tap still works on most outputs, and the SCKit fallback
    /// is the conservative side to bias toward only when we actually know it's Bluetooth.
    static func isDefaultOutputBluetooth() -> Bool {
        guard let deviceID = try? defaultOutputDeviceID() else { return false }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &transport)
        guard status == noErr else { return false }
        return transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
    }
}
