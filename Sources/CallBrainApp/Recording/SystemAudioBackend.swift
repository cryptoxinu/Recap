import Foundation
import CallBrainAppCore

/// The contract every system-audio capture backend fulfils, so `AudioCapture` can hold either the
/// ScreenCaptureKit path (`SystemAudioCapture`) or the Core Audio process tap (`CoreAudioTapCapture`)
/// behind one type. Both deliver the SAME thing to the recorder: `Int16` 16 kHz mono samples plus a
/// mach-clock capture timestamp in nanoseconds, via the `onSamples` closure passed to their init.
///
/// `AnyObject` — backends are reference types owning live capture sessions.
/// `Sendable` — a backend is started/stopped from `@MainActor` but runs its capture off-main on its
/// own serial queues; conformers are `@unchecked Sendable` and own their synchronization. A backend
/// must NEVER be `@MainActor` (that would serialize capture onto the UI thread).
protocol SystemAudioBackend: AnyObject, Sendable {
    /// Start capture best-effort. NEVER throws — a failure degrades to mic-only plus a visible warning
    /// and returns a `.failed` state. Returns the state reached so the caller can react immediately.
    @discardableResult
    func startBestEffort() async -> SystemAudioCaptureState

    /// Stop capture and release all resources. Idempotent and best-effort — safe to call when never
    /// started or already stopped.
    func stop() async
}
