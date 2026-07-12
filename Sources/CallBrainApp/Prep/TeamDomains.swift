import Foundation
import CallBrainCore

/// The founder's own org email domains — used to tell teammates from external guests in attendee
/// research. Sourced from an explicit Settings override, plus an auto-derived set learned from the
/// dominant non-free-mail domain across the loaded calendar (the founder is on nearly every own call).
enum TeamDomains {
    static let overrideKey = "callbrain.teamDomains"          // user-set, comma-separated
    static let derivedKey  = "callbrain.teamDomainsDerived"   // auto-learned cache

    /// The effective team-domain set = explicit override ∪ auto-derived.
    static func current() -> Set<String> {
        parse(UserDefaults.standard.string(forKey: overrideKey))
            .union(Set(UserDefaults.standard.stringArray(forKey: derivedKey) ?? []))
    }

    /// Learn team domains from the currently-loaded events and cache them (best-effort). Prefers the
    /// PRECISE signal — the founder's own email domain (from their identity) — and only falls back to
    /// frequency derivation when the founder's own email hasn't been seen yet, so a recurring EXTERNAL
    /// partner can't be miscached as "team" once we know the real domain (review LOW). Unions with the
    /// existing cache (grows monotonically) so a sparse refresh never erases prior learning.
    static func updateDerived(from events: [CalendarEvent]) {
        let emails = events.flatMap(\.attendeeEmails)
        guard !emails.isEmpty else { return }
        let founder = AttendeeResearch.founderDomains(inEmails: emails, aliases: FounderIdentity.aliases)
        let learned = founder.isEmpty ? AttendeeResearch.deriveTeamDomains(fromEmails: emails) : founder
        guard !learned.isEmpty else { return }
        let existing = Set(UserDefaults.standard.stringArray(forKey: derivedKey) ?? [])
        UserDefaults.standard.set(Array(existing.union(learned)).sorted(), forKey: derivedKey)
    }

    /// Parse the comma-separated override into a clean domain set. Tolerant of the natural ways a user
    /// writes a domain (audit EDGE: "@acme.com" and a pasted "alex@acme.com" were silently DROPPED,
    /// yielding an empty team set → teammates mis-researched as outside guests): an "@" segment is
    /// normalized to the domain part, and stray leading/trailing dots are trimmed. Truly invalid tokens
    /// (no dot) are still dropped; SettingsView surfaces an inline hint when nothing valid parses.
    static func parse(_ raw: String?) -> Set<String> {
        Set((raw ?? "").split(separator: ",")
            .map { tok -> String in
                let t = tok.trimmingCharacters(in: .whitespaces).lowercased()
                let domain = t.contains("@") ? String(t.split(separator: "@").last ?? "") : t
                return domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            }
            .filter { $0.contains(".") })
    }

    /// True when the user typed something in the override but NONE of it parsed to a valid domain — used
    /// by Settings to show an inline "use e.g. acme.com" hint instead of silently doing nothing.
    static func overrideHasInvalidOnly(_ raw: String) -> Bool {
        let typed = raw.split(separator: ",").contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return typed && parse(raw).isEmpty
    }
}
