import Foundation

/// One line of AI notes — a section HEADER (from a template) or a bullet under it. Lets the "notes that
/// write themselves" render as real Granola-style sections, not a flat list.
public struct NoteLine: Codable, Equatable, Sendable {
    public var text: String
    public var isHeader: Bool
    public init(text: String, isHeader: Bool) { self.text = text; self.isHeader = isHeader }
}

/// A meeting-note TEMPLATE (Granola Phase C): shapes how the AI structures the running notes for a KIND
/// of meeting. `instructions` are the section list injected into the summarize prompt — empty means plain
/// bullets (the "General" default). Built-ins ship; users can add their own.
public struct NoteTemplate: Codable, Equatable, Sendable, Identifiable {
    public var id: String        // stable slug
    public var name: String
    public var icon: String      // SF Symbol
    public var instructions: String   // section structure; "" → plain bullets
    public var isBuiltIn: Bool

    public init(id: String, name: String, icon: String, instructions: String, isBuiltIn: Bool = false) {
        self.id = id; self.name = name; self.icon = icon
        self.instructions = instructions; self.isBuiltIn = isBuiltIn
    }

    public static let general = NoteTemplate(id: "general", name: "General", icon: "doc.text",
                                             instructions: "", isBuiltIn: true)

    /// The shipped templates. Section lists are phrased as the model should output them.
    public static let builtIns: [NoteTemplate] = [
        general,
        NoteTemplate(id: "one_on_one", name: "1:1", icon: "person.2",
                     instructions: "Wins; Blockers; Feedback; Action items", isBuiltIn: true),
        NoteTemplate(id: "sales_discovery", name: "Sales / Discovery", icon: "dollarsign.circle",
                     instructions: "Pain points; Current solution; Budget & timeline; Objections; Next steps",
                     isBuiltIn: true),
        NoteTemplate(id: "standup", name: "Standup", icon: "checklist",
                     instructions: "Done; In progress; Blockers", isBuiltIn: true),
        NoteTemplate(id: "interview", name: "Interview", icon: "person.crop.rectangle",
                     instructions: "Background; Strengths; Concerns; Fit; Next steps", isBuiltIn: true),
        NoteTemplate(id: "investor", name: "Investor pitch", icon: "chart.line.uptrend.xyaxis",
                     instructions: "The ask; Traction; Team; Risks; Follow-ups", isBuiltIn: true),
        NoteTemplate(id: "partnership", name: "Partnership / BD", icon: "link",
                     instructions: "Proposal; Terms; Technical; Risks; Next steps", isBuiltIn: true),
        NoteTemplate(id: "brainstorm", name: "Brainstorm", icon: "lightbulb",
                     instructions: "Ideas; Decisions; Open questions", isBuiltIn: true),
    ]
}

/// The user's template library: the shipped built-ins + their own custom templates, plus the default
/// selection. Persisted in UserDefaults (mirrors `CorrectionDictionary`).
public struct NoteTemplateLibrary: Codable, Equatable, Sendable {
    public var custom: [NoteTemplate]
    /// The template chosen by default for a new recording.
    public var defaultID: String

    public init(custom: [NoteTemplate] = [], defaultID: String = NoteTemplate.general.id) {
        self.custom = custom; self.defaultID = defaultID
    }

    /// Built-ins first, then the user's custom templates.
    public var all: [NoteTemplate] { NoteTemplate.builtIns + custom }

    public func template(id: String) -> NoteTemplate? { all.first { $0.id == id } }

    public var defaultTemplate: NoteTemplate { template(id: defaultID) ?? .general }

    // MARK: Mutation (immutable)

    /// Add or replace a custom template (keyed by id). Built-in ids are ignored (can't shadow a built-in).
    public func upserting(_ t: NoteTemplate) -> NoteTemplateLibrary {
        guard !NoteTemplate.builtIns.contains(where: { $0.id == t.id }) else { return self }
        var copy = self
        var entry = t; entry.isBuiltIn = false
        if let i = copy.custom.firstIndex(where: { $0.id == t.id }) { copy.custom[i] = entry }
        else { copy.custom.append(entry) }
        return copy
    }

    public func removingCustom(id: String) -> NoteTemplateLibrary {
        var copy = self
        copy.custom.removeAll { $0.id == id }
        if copy.defaultID == id { copy.defaultID = NoteTemplate.general.id }
        return copy
    }

    public func settingDefault(id: String) -> NoteTemplateLibrary {
        guard all.contains(where: { $0.id == id }) else { return self }
        var copy = self; copy.defaultID = id; return copy
    }

    // MARK: Persistence

    public static let defaultsKey = "callbrain.noteTemplates.v1"

    public func save(key: String = Self.defaultsKey) {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: key) }
    }

    public static func load(key: String = Self.defaultsKey) -> NoteTemplateLibrary {
        guard let data = UserDefaults.standard.data(forKey: key),
              var lib = try? JSONDecoder().decode(NoteTemplateLibrary.self, from: data) else {
            return NoteTemplateLibrary()
        }
        // Sanitize decoded data (corruption / an old build): drop custom templates with an empty id, one
        // that collides with a built-in, or a duplicate; reset a dangling default to General.
        let builtInIDs = Set(NoteTemplate.builtIns.map(\.id))
        var seen = builtInIDs
        lib.custom = lib.custom.compactMap { t in
            guard !t.id.isEmpty, !seen.contains(t.id) else { return nil }
            seen.insert(t.id)
            var c = t; c.isBuiltIn = false; return c
        }
        if lib.all.first(where: { $0.id == lib.defaultID }) == nil { lib.defaultID = NoteTemplate.general.id }
        return lib
    }
}
