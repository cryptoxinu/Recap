import Foundation

/// Recap is a SINGLE-USER app — every call and task is for its one user. This resolves whether an
/// action item is "mine": it belongs to the user when it's explicitly theirs, org-wide/team (they're in
/// the org), or unassigned (a stray untagged to-do defaults to yours so nothing is hidden). A task
/// explicitly owned by someone ELSE (a named teammate) is NOT mine.
///
/// The user tells Recap their name(s) in Settings (UserDefaults `callbrain.founderNames`,
/// comma-separated) so the AI can attribute correctly; until then the alias set is empty.
public enum FounderIdentity {
    public static let defaultsKey = "callbrain.founderNames"
    static let fallback: [String] = []   // no baked-in personal name — the user provides theirs in Settings

    /// Lowercased alias set from Settings (empty until the user enters their name(s)).
    public static var aliases: [String] {
        let raw = UserDefaults.standard.string(forKey: defaultsKey) ?? ""
        let custom = raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        return custom.isEmpty ? fallback : custom
    }

    /// Owners meaning "the whole group" — which includes the founder, so these count as mine.
    static let orgWide: Set<String> = ["everyone", "all", "team", "us", "the team", "our team", "org",
                                       "the org", "everybody", "all of us", "we", "group", "whole team"]

    /// A human-facing primary name for prompts + the "For you" UI.
    public static var displayName: String {
        guard let first = aliases.first, !first.isEmpty else { return "you" }
        return first.prefix(1).uppercased() + first.dropFirst()
    }

    /// Does this owner string name the founder SPECIFICALLY (alias match)? Narrower than
    /// `isMine` — unassigned and org-wide items count as "mine" but are not an alias match.
    /// Task 1.3 uses this to fold every variant of the user's name into ONE "You" section in Tasks.
    public static func isAlias(_ owner: String?) -> Bool { isAlias(owner, aliases: aliases) }

    /// Overload with a precomputed alias set — `aliases` re-reads + re-parses UserDefaults per
    /// call, so per-row render loops (TasksView) must resolve it ONCE (Codex phase-1 LOW).
    public static func isAlias(_ owner: String?, aliases al: [String]) -> Bool {
        let o = (owner ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !o.isEmpty, !orgWide.contains(o) else { return false }
        if al.contains(o) { return true }
        // WHOLE-TOKEN match ONLY, so "Alex Kim", "Alex K.", "alex (founder)" resolve to the "alex" alias
        // with NO substring false positives — neither a short nickname ("aj"→"Raj", "al"→"Alice") nor a
        // 4+ char name inside a longer one ("john"→"johnson", "mary"→"rosemary", "anna"→"hannah") can match
        // (audit: any substring branch reintroduces misattribution of a teammate's task to the founder).
        let tokens = Set(o.split(whereSeparator: { !$0.isLetter }).map(String.init))
        return al.contains { tokens.contains($0) }
    }

    /// Is this owner the founder's to-do (theirs, org-wide, or unassigned)? False only when it's clearly
    /// someone else's.
    public static func isMine(_ owner: String?) -> Bool { isMine(owner, aliases: aliases) }

    public static func isMine(_ owner: String?, aliases al: [String]) -> Bool {
        let o = (owner ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if o.isEmpty { return true }                       // unassigned → default to yours
        if orgWide.contains(o) { return true }             // org-wide → yours (you're in the org)
        return isAlias(owner, aliases: al)
    }
}
