import Foundation

public enum SystemAudioCaptureState: Equatable, Sendable {
    case off
    case starting
    case capturing
    case receiving
    case noSamples
    case failed(String)
}

public enum SystemAudioHealth {
    public static let micOnlyWarning = "System audio was not captured - only your mic was recorded."

    public static func stateAfterWatchdog(
        includeSystemAudio: Bool,
        current: SystemAudioCaptureState,
        receivedSamples: Bool
    ) -> SystemAudioCaptureState {
        guard includeSystemAudio else { return .off }
        if receivedSamples { return .receiving }
        switch current {
        case .starting, .capturing:
            return .noSamples
        case .off, .receiving, .noSamples, .failed:
            return current
        }
    }

    public static func stopWarning(
        includeSystemAudio: Bool,
        state: SystemAudioCaptureState
    ) -> String? {
        guard includeSystemAudio else { return nil }
        switch state {
        case .receiving:
            return nil
        case .failed(let reason):
            return "System audio was not captured (\(reason)) - only your mic was recorded."
        case .starting, .capturing, .noSamples:
            return micOnlyWarning
        case .off:
            return nil
        }
    }
}
