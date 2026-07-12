import Foundation

/// A user-defined "venture" a call can belong to — the founder's own companies/projects, entered in
/// Settings (NOT hardcoded, so the shipped/committed app carries no personal company names). Each
/// venture is a label + the keywords that identify its calls; the `id` is a stable slug that is also
/// the string stored in `meetings.category`, so existing tagged calls survive edits.
public struct Venture: Codable, Sendable, Equatable, Hashable, Identifiable {
    public let id: String            // stable slug (== stored category value)
    public var label: String
    public var keywords: [String]    // lowercased match terms
    public var colorHex: String?     // optional custom tint; else a palette hue by position
    public init(id: String, label: String, keywords: [String], colorHex: String? = nil) {
        self.id = id; self.label = label; self.keywords = keywords; self.colorHex = colorHex
    }
}

/// The reserved id for "not one of the user's ventures" — always present, never user-defined.
public let kOtherVentureID = "other"

/// Loads/saves the user's ventures from UserDefaults. SHIPS EMPTY: a fresh or shared install has no
/// ventures until the user adds them in Settings, so no company name is baked into the source.
public enum VentureConfig {
    public static let defaultsKey = "callbrain.ventures"

    /// Shipped default — deliberately empty so the committed app reveals nothing personal.
    public static let shipped: [Venture] = []

    public static func load(_ defaults: UserDefaults = .standard) -> [Venture] {
        guard let data = defaults.data(forKey: defaultsKey),
              let v = try? JSONDecoder().decode([Venture].self, from: data) else { return shipped }
        return v
    }

    public static func save(_ ventures: [Venture], _ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(ventures) { defaults.set(data, forKey: defaultsKey) }
    }

    /// The display label for a stored category id (venture label, "Other", or the raw id titlecased
    /// for an orphaned id whose venture was deleted).
    public static func label(for id: String?, in ventures: [Venture]) -> String {
        guard let id, !id.isEmpty, id != kOtherVentureID else { return "Other" }
        if let v = ventures.first(where: { $0.id == id }) { return v.label }
        return id.replacingOccurrences(of: "_", with: " ").capitalized
    }

    /// A FRESH, unique id for a newly-added venture: the readable slug plus a short random suffix. The
    /// suffix guarantees a deleted venture's id is NEVER reused, so old calls still tagged with the old id
    /// can't be silently reattributed to a same-named new venture (audit #6). Avoids `existing` ids too.
    public static func freshID(for label: String, existing: [String], random: () -> UInt32 = { UInt32.random(in: 0..<0x10000) }) -> String {
        let base = slug(label)
        let taken = Set(existing)
        for _ in 0..<64 {
            let id = "\(base)-\(String(format: "%04x", random() & 0xffff))"
            if !taken.contains(id) { return id }
        }
        return "\(base)-\(String(format: "%08x", random()))"   // pathological fallback
    }

    /// A URL/DB-safe stable slug from a label: lowercased, non-alphanumerics → "_", collapsed/trimmed.
    /// Never yields the reserved "other" or an empty string.
    public static func slug(_ label: String) -> String {
        let lowered = label.lowercased()
        let mapped = lowered.map { $0.isLetter || $0.isNumber ? $0 : "_" }
        var s = String(mapped)
        while s.contains("__") { s = s.replacingOccurrences(of: "__", with: "_") }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        if s.isEmpty { s = "venture" }
        if s == kOtherVentureID { s = "venture_other" }
        return s
    }
}
