import AppKit
import Carbon.HIToolbox

/// Task 9.1 (gate MED: a MenuBarExtra item shortcut is NOT a global hotkey) — a real
/// system-wide hotkey via Carbon RegisterEventHotKey. ⌥⌘Space summons Ask from ANY app.
/// No accessibility permission needed (unlike CGEventTap).
@MainActor
enum GlobalHotkey {
    private static var hotKeyRef: EventHotKeyRef?
    private static var handlerRef: EventHandlerRef?
    private static var action: (() -> Void)?

    /// Register ⌥⌘Space. Idempotent; statuses CHECKED so a failed registration can't leave a
    /// dangling handler or stack duplicates on a retried .task (r2 LOW).
    static func install(_ fire: @escaping () -> Void) {
        guard hotKeyRef == nil, handlerRef == nil else { return }
        action = fire

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
            DispatchQueue.main.async { MainActor.assumeIsolated { GlobalHotkey.action?() } }
            return noErr
        }, 1, &eventType, nil, &handlerRef)
        guard installed == noErr, handlerRef != nil else { handlerRef = nil; action = nil; return }

        let hotKeyID = EventHotKeyID(signature: OSType(0x43424B48 /* 'CBKH' */), id: 1)
        let registered = RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey | cmdKey),
                                             hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        if registered != noErr || hotKeyRef == nil {   // roll back — no half-installed state
            if let h = handlerRef { RemoveEventHandler(h) }
            handlerRef = nil; hotKeyRef = nil; action = nil
        }
    }
}
