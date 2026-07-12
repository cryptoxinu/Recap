import Foundation

/// A user-taught blocklist of names that are NOT people — set via right-click → "Not a person" in the
/// People tab. Persisted (UserDefaults) so the roster never lists them again. This is the founder-driven
/// complement to the automatic noise filter for the inherently ambiguous cases on-device NER can't resolve
/// on its own (an AI product literally named "Pearl", a mis-glued fragment like "Andy and.x"). Matched
/// exactly (case-insensitive) against the DISPLAY name the user actually saw and dismissed.
enum NotPeople {
    static let defaultsKey = "callbrain.notPeople"

    /// Lowercased blocklisted display names — passed into `Store.people(blocklist:)`.
    static func current() -> Set<String> {
        Set((UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []).map { $0.lowercased() })
    }

    /// The raw display list (newest kept as entered; sorted for a stable Settings review surface).
    static func list() -> [String] { (UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []).sorted() }

    static func add(_ name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        var list = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
        guard !list.contains(where: { $0.caseInsensitiveCompare(n) == .orderedSame }) else { return }
        list.append(n)
        UserDefaults.standard.set(list.sorted(), forKey: defaultsKey)
    }

    /// Undo — restore a name the user blocklisted by mistake.
    static func remove(_ name: String) {
        let list = (UserDefaults.standard.stringArray(forKey: defaultsKey) ?? [])
            .filter { $0.caseInsensitiveCompare(name) != .orderedSame }
        UserDefaults.standard.set(list, forKey: defaultsKey)
    }
}
