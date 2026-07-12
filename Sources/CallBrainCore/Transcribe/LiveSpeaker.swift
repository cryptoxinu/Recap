/// Speaker labels for live audio capture: the mic stream is `You`, and the system-audio stream is
/// `Them` because it excludes this app's own process and contains the remote participants only.
public enum LiveSpeaker: String, Sendable, CaseIterable, Codable {
    case you = "You"
    case them = "Them"
}
