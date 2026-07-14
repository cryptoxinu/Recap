import Foundation

/// Choose the transcript both the in-call catch-up assistant AND the auto-notes read during a live call:
/// PREFER the extension's named Google Meet captions when they're present, otherwise fall back to the
/// on-device You/Them audio transcript (CC off, extension not paired, or a non-Meet call).
///
/// This is what stops the AI notes from writing "Them has a PR…": the display panel already prefers the
/// named captions, and now the assistant/notes read from the same named source when it exists.
///
/// Pure and side-effect-free so the preference is unit-tested without standing up a whole recording.
public func preferredLiveTranscript(captions: String, audio: String) -> String {
    captions.isEmpty ? audio : captions
}
