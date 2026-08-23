import Foundation
import CoreAudio
import AudioToolbox
import AVFoundation

/// Low-level Core Audio process-tap wrapper: builds a mono, global, exclude-own-process tap, wraps it
/// in a private aggregate device tracking the real default output, installs an IOProc, and hands the
/// raw f32 frames + a mach-clock capture timestamp off the real-time thread. It does NO conversion,
/// NO file I/O, and NO SwiftUI — that all lives above it in `CoreAudioTapCapture`.
///
/// Concurrency: every create/destroy/rebuild happens on a single serial `lifecycleQueue` (property
/// listeners fire there too, so a sample-rate change or a default-output switch is serialized against
/// start/stop and can never race). The IOProc runs on a separate high-QoS `ioQueue` and only copies +
/// hands off. `@unchecked Sendable` — the class owns its own synchronization; it is NEVER `@MainActor`.
@available(macOS 14.4, *)
final class CoreAudioProcessTap: @unchecked Sendable {

    /// A Core Audio HAL failure, carrying the failing step + OSStatus for logs.
    struct TapError: Error, CustomStringConvertible {
        let step: String
        let status: OSStatus
        var description: String { "CoreAudioProcessTap.\(step) failed (OSStatus \(status))" }
    }

    /// Called on `ioQueue` (RT thread) with a copy of the tap's f32 mono frames + capture ns. MUST be
    /// cheap on the caller side — downsampling/I/O happens off this queue in `CoreAudioTapCapture`.
    private let onRawFrames: @Sendable ([Float], UInt64) -> Void
    /// Called on `lifecycleQueue` when the tap's stream format changes mid-capture (so the downsampler
    /// can rebuild its converter). Never called from the RT thread.
    private let onFormatChange: @Sendable (AudioStreamBasicDescription) -> Void

    private let lifecycleQueue = DispatchQueue(label: "callbrain.coreaudio.tap.lifecycle")
    private let ioQueue = DispatchQueue(label: "callbrain.coreaudio.tap.io", qos: .userInitiated)

    // All mutated only on lifecycleQueue.
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var tapUUIDString = ""
    private var torndown = false

    private var formatListener: AudioObjectPropertyListenerBlock?
    private var outputListener: AudioObjectPropertyListenerBlock?

    init(onRawFrames: @escaping @Sendable ([Float], UInt64) -> Void,
         onFormatChange: @escaping @Sendable (AudioStreamBasicDescription) -> Void) {
        self.onRawFrames = onRawFrames
        self.onFormatChange = onFormatChange
    }

    // MARK: - Start / stop (public, serialized)

    /// Build the whole tap → aggregate → IOProc chain and start it. Returns the tap's initial stream
    /// format so the caller can size its downsampler. Throws on any HAL failure, having first torn down
    /// any partial setup so nothing leaks.
    func start() throws -> AudioStreamBasicDescription {
        try lifecycleQueue.sync {
            torndown = false
            do {
                let asbd = try buildTapLocked()
                installFormatListenerLocked()
                let outputUID = try AudioDeviceQuery.defaultOutputUID()
                try buildAggregateAndIOLocked(outputUID: outputUID)
                installOutputListenerLocked()
                return asbd
            } catch {
                teardownAllLocked()   // clean the partial chain — never leak a tap/aggregate.
                throw error
            }
        }
    }

    /// Ordered, idempotent, best-effort teardown. Safe to call when never started or already stopped.
    func stop() {
        lifecycleQueue.sync { teardownAllLocked() }
    }

    // MARK: - Build steps (must run on lifecycleQueue)

    private func buildTapLocked() throws -> AudioStreamBasicDescription {
        // Exclude our own process so we never record CallBrain's own sounds (mirrors the SCKit path's
        // excludesCurrentProcessAudio). Best-effort: if the PID→object translation fails we exclude
        // nothing rather than fail the whole tap.
        let excluded: [AudioObjectID] = (try? processObjectID(for: getpid())).map { [$0] } ?? []
        let desc = CATapDescription(monoGlobalTapButExcludeProcesses: excluded)
        desc.name = "CallBrain System Tap"
        desc.uuid = UUID()
        desc.muteBehavior = .unmuted     // never mute the user's own playback while we tap it.
        desc.isPrivate = true            // don't publish the tap to other apps.
        desc.isExclusive = false         // global (exclude-list) semantics.
        tapUUIDString = desc.uuid.uuidString

        var newTap = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(desc, &newTap)
        guard status == noErr, newTap != AudioObjectID(kAudioObjectUnknown) else {
            throw TapError(step: "createProcessTap", status: status)
        }
        tapID = newTap
        return try tapStreamFormatLocked()
    }

    private func buildAggregateAndIOLocked(outputUID: String) throws {
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "CallBrain-Aggregate-\(getpid())",
            kAudioAggregateDeviceUIDKey as String: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey as String: outputUID,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceSubDeviceListKey as String: [
                [kAudioSubDeviceUIDKey as String: outputUID]
            ],
            kAudioAggregateDeviceTapListKey as String: [
                [
                    kAudioSubTapDriftCompensationKey as String: true,
                    kAudioSubTapUIDKey as String: tapUUIDString,
                ]
            ],
        ]

        var newAgg = AudioObjectID(kAudioObjectUnknown)
        let createStatus = AudioHardwareCreateAggregateDevice(description as CFDictionary, &newAgg)
        guard createStatus == noErr, newAgg != AudioObjectID(kAudioObjectUnknown) else {
            throw TapError(step: "createAggregateDevice", status: createStatus)
        }
        aggregateID = newAgg

        var newProc: AudioDeviceIOProcID?
        let ioStatus = AudioDeviceCreateIOProcIDWithBlock(&newProc, newAgg, ioQueue) {
            [weak self] _, inInputData, inInputTime, _, _ in
            guard let self else { return }
            // 1) Capture time on the mach host clock → ns (SAME domain as the mic tap + SCKit path).
            let ts = inInputTime.pointee
            let nanos: UInt64 = ts.mFlags.contains(.hostTimeValid)
                ? hostTicksToNanos(ts.mHostTime)
                : DispatchTime.now().uptimeNanoseconds
            // 2) Pull f32 mono frames out of the first buffer (mono tap → one buffer).
            let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            guard let buffer = abl.first, let mData = buffer.mData, buffer.mDataByteSize > 0 else { return }
            let frameCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            let floats = Array(UnsafeBufferPointer(
                start: mData.assumingMemoryBound(to: Float.self), count: frameCount))
            // 3) Hand OFF the RT thread immediately — no conversion / no I/O here.
            self.onRawFrames(floats, nanos)
        }
        guard ioStatus == noErr, newProc != nil else {
            throw TapError(step: "createIOProc", status: ioStatus)
        }
        procID = newProc

        let startStatus = AudioDeviceStart(newAgg, newProc)
        guard startStatus == noErr else {
            throw TapError(step: "deviceStart", status: startStatus)
        }
    }

    // MARK: - Teardown (must run on lifecycleQueue)

    /// Tear down only the aggregate + IOProc (keeps the tap + listeners) — used on a default-output
    /// change before rebuilding the aggregate against the new output.
    private func teardownAggregateAndIOLocked() {
        if aggregateID != AudioObjectID(kAudioObjectUnknown), let proc = procID {
            _ = AudioDeviceStop(aggregateID, proc)
            _ = AudioDeviceDestroyIOProcID(aggregateID, proc)
        }
        procID = nil
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            _ = AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    /// Full ordered teardown (exact reverse of setup) — every step best-effort, never throws.
    private func teardownAllLocked() {
        guard !torndown else { return }
        torndown = true
        teardownAggregateAndIOLocked()
        removeListenersLocked()
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            _ = AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        tapUUIDString = ""
    }

    // MARK: - Property listeners (fire on lifecycleQueue)

    private func installFormatListenerLocked() {
        guard tapID != AudioObjectID(kAudioObjectUnknown) else { return }
        var addr = Self.tapFormatAddress
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            // Already on lifecycleQueue (registered with it). Re-read the ASBD and notify.
            if let asbd = try? self.tapStreamFormatLocked() {
                self.onFormatChange(asbd)
            }
        }
        let status = AudioObjectAddPropertyListenerBlock(tapID, &addr, lifecycleQueue, block)
        if status == noErr { formatListener = block }
    }

    private func installOutputListenerLocked() {
        var addr = Self.defaultOutputAddress
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, !self.torndown else { return }
            // The user switched speakers/headset mid-call. Rebuild the aggregate against the new output
            // (the tap itself is process-based and stays). A brief gap during rebuild just leaves a
            // short silence on the capture-ns timeline — far better than tapping a dead device.
            self.teardownAggregateAndIOLocked()
            if let uid = try? AudioDeviceQuery.defaultOutputUID() {
                try? self.buildAggregateAndIOLocked(outputUID: uid)
            }
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, lifecycleQueue, block)
        if status == noErr { outputListener = block }
    }

    private func removeListenersLocked() {
        if let block = formatListener, tapID != AudioObjectID(kAudioObjectUnknown) {
            var addr = Self.tapFormatAddress
            _ = AudioObjectRemovePropertyListenerBlock(tapID, &addr, lifecycleQueue, block)
        }
        formatListener = nil
        if let block = outputListener {
            var addr = Self.defaultOutputAddress
            _ = AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &addr, lifecycleQueue, block)
        }
        outputListener = nil
    }

    // MARK: - Property reads

    private func tapStreamFormatLocked() throws -> AudioStreamBasicDescription {
        var addr = Self.tapFormatAddress
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd)
        guard status == noErr else { throw TapError(step: "tapFormat", status: status) }
        return asbd
    }

    private func processObjectID(for pid: pid_t) throws -> AudioObjectID {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var pidVar = pid
        var objID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &pidVar) { qptr -> OSStatus in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &addr,
                UInt32(MemoryLayout<pid_t>.size), qptr, &size, &objID)
        }
        guard status == noErr else { throw TapError(step: "translatePID", status: status) }
        return objID
    }

    // Computed (not stored `static let`) so we don't hold a non-Sendable C struct as shared global
    // state under Swift 6 — each read builds a fresh, trivial value.
    private static var tapFormatAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    private static var defaultOutputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }
}
