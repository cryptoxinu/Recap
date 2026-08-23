import Testing
import Foundation
@testable import CallBrainAppCore

/// Pure decision-logic tests for the system-audio backend selector. No Core Audio, no hardware —
/// `resolve` takes injected `isBluetooth` / `tapAvailable` flags, and the persisted preference is
/// read from a throwaway UserDefaults suite so the founder's real settings are never touched.
@Suite("System audio backend selection")
struct SystemAudioBackendTests {

    // MARK: - Enum raw-value round-trip + default

    @Test("raw values round-trip through the persisted string")
    func rawValuesRoundTrip() {
        for kind in SystemAudioBackendKind.allCases {
            #expect(SystemAudioBackendKind(rawValue: kind.rawValue) == kind)
        }
        // Stable raw strings (the persisted contract — don't rename without a migration).
        #expect(SystemAudioBackendKind.auto.rawValue == "auto")
        #expect(SystemAudioBackendKind.coreAudioTap.rawValue == "coreAudioTap")
        #expect(SystemAudioBackendKind.screenCapture.rawValue == "screenCapture")
    }

    @Test("unset or unknown preference defaults to .auto")
    func unsetDefaultsToAuto() throws {
        let suite = "callbrain.tests.backend.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        // Nothing stored yet.
        #expect(SystemAudioBackendKind.current(defaults) == .auto)
        // Garbage stored → still .auto (never crash on a bad string).
        defaults.set("not-a-backend", forKey: SystemAudioBackendKind.defaultsKey)
        #expect(SystemAudioBackendKind.current(defaults) == .auto)
        // A valid stored value round-trips.
        defaults.set(SystemAudioBackendKind.coreAudioTap.rawValue, forKey: SystemAudioBackendKind.defaultsKey)
        #expect(SystemAudioBackendKind.current(defaults) == .coreAudioTap)
    }

    // MARK: - resolve(): the Phase-B effective backend

    @Test("PHASE B: .auto (the default) resolves to .screenCapture — the working recorder is unchanged")
    func autoResolvesToScreenCaptureInPhaseB() {
        // The key assertion of this whole change: the effective default is ScreenCaptureKit.
        #expect(SystemAudioBackendKind.autoPrefersTap == false)
        #expect(SystemAudioBackendKind.resolve(.auto, isBluetooth: false, tapAvailable: true) == .screenCapture)
        #expect(SystemAudioBackendKind.resolve(.auto, isBluetooth: true, tapAvailable: true) == .screenCapture)
    }

    @Test("explicit .coreAudioTap on non-Bluetooth output resolves to the tap")
    func explicitTapNonBluetooth() {
        #expect(SystemAudioBackendKind.resolve(.coreAudioTap, isBluetooth: false, tapAvailable: true) == .coreAudioTap)
    }

    @Test("explicit .coreAudioTap on Bluetooth output falls back to ScreenCaptureKit")
    func explicitTapBluetoothFallsBack() {
        // A Bluetooth output can make the tap miss the remote party — safer to record via SCKit.
        #expect(SystemAudioBackendKind.resolve(.coreAudioTap, isBluetooth: true, tapAvailable: true) == .screenCapture)
    }

    @Test("explicit .screenCapture is always honored")
    func explicitScreenCapture() {
        #expect(SystemAudioBackendKind.resolve(.screenCapture, isBluetooth: false, tapAvailable: true) == .screenCapture)
        #expect(SystemAudioBackendKind.resolve(.screenCapture, isBluetooth: true, tapAvailable: true) == .screenCapture)
    }

    @Test("no tap available (macOS < 14.4) always resolves to ScreenCaptureKit")
    func tapUnavailableAlwaysScreenCapture() {
        for kind in SystemAudioBackendKind.allCases {
            #expect(SystemAudioBackendKind.resolve(kind, isBluetooth: false, tapAvailable: false) == .screenCapture)
            #expect(SystemAudioBackendKind.resolve(kind, isBluetooth: true, tapAvailable: false) == .screenCapture)
        }
    }
}
