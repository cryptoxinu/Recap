import Foundation

/// Calendar v4 — a proposed new/edited calendar event, provider-agnostic. The app maps this
/// onto an EKEvent to write. Pure value type so parsing + validation stay testable.
public struct EventDraft: Sendable, Equatable {
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var location: String?
    public var notes: String?
    public var attendees: [String]        // display names / emails typed by the user
    public var calendarName: String?      // target calendar; nil = default

    public init(title: String, start: Date, end: Date, isAllDay: Bool = false,
                location: String? = nil, notes: String? = nil,
                attendees: [String] = [], calendarName: String? = nil) {
        self.title = title; self.start = start; self.end = end; self.isAllDay = isAllDay
        self.location = location; self.notes = notes
        self.attendees = attendees; self.calendarName = calendarName
    }
}

/// A concrete edit the app hands to the EventKit writer. `eventID` is the source-qualified
/// `CalendarEvent.id` for update/delete; nil for create.
public struct EventEdit: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case create, update, delete }
    public let kind: Kind
    public let eventID: String?
    public let draft: EventDraft?
    public init(kind: Kind, eventID: String?, draft: EventDraft?) {
        self.kind = kind; self.eventID = eventID; self.draft = draft
    }
    public static func create(_ d: EventDraft) -> EventEdit { .init(kind: .create, eventID: nil, draft: d) }
    public static func update(_ id: String, _ d: EventDraft) -> EventEdit { .init(kind: .update, eventID: id, draft: d) }
    public static func delete(_ id: String) -> EventEdit { .init(kind: .delete, eventID: id, draft: nil) }
}
