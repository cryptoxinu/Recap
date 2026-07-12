import Foundation

/// Filename conventions for the auxiliary files a recording writes next to its main WAV.
public enum RecordingSidecars {
    /// The remote-participants-only (system audio) sibling for a recording's WAV, used for dual-channel
    /// group-speaker attribution (T3). It is a HIDDEN `.system.wav` (dot-prefixed) so `RecordingStorage`
    /// listing/clearing and any folder-import scan (all `.skipsHiddenFiles`) never surface it as a
    /// recording or a transcript to import — while keeping the `.wav` content AVFoundation can decode.
    public static func systemAudioURL(forRecording wav: URL) -> URL {
        let stem = wav.deletingPathExtension().lastPathComponent
        return wav.deletingLastPathComponent().appendingPathComponent(".\(stem).system.wav")
    }
}
