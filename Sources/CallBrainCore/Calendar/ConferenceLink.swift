import Foundation

/// Calendar v3 — detects a joinable video-conference URL in an event's url / location / notes
/// (in that precedence) for the detail panel's "Join call" button. Known hosts only, matched
/// by exact host or dot-boundary suffix — "notzoom.us" and "zoom.us.evil.com" never match.
public enum ConferenceLink {

    static let hosts: [String] = [
        "zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com",
        "webex.com", "whereby.com",
    ]

    public static func detect(in event: CalendarEvent) -> URL? {
        for text in [event.url, event.location, event.notes] {
            if let text, let url = firstConferenceURL(in: text) { return url }
        }
        return nil
    }

    static func firstConferenceURL(in text: String) -> URL? {
        guard text.localizedCaseInsensitiveContains("http") else { return nil }
        // https ONLY (audit LOW): calendar text is untrusted — never surface a Join button
        // for a plaintext-transport URL.
        let pattern = #"https://[^\s<>"'\)\]]+"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = text as NSString
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            var raw = ns.substring(with: m.range)
            while let last = raw.last, ".,;:!?…—".contains(last) { raw.removeLast() }
            guard let url = URL(string: raw), let host = url.host?.lowercased() else { continue }
            if hosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return url }
        }
        return nil
    }
}
