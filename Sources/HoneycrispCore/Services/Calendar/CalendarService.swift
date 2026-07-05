import Foundation

/// One calendar event as the model sees it. The url is the event's URL
/// field, which Calendar shows in the event inspector.
public struct CalendarEvent: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let calendar: String
    public let start: Date
    public let end: Date
    public let allDay: Bool
    public let location: String?
    public let notes: String?
    public let url: String?

    public init(
        id: String, title: String, calendar: String, start: Date, end: Date,
        allDay: Bool, location: String?, notes: String?, url: String? = nil
    ) {
        self.id = id
        self.title = title
        self.calendar = calendar
        self.start = start
        self.end = end
        self.allDay = allDay
        self.location = location
        self.notes = notes
        self.url = url
    }
}

/// What calendar_create accepts after argument parsing.
public struct NewEvent: Codable, Equatable, Sendable {
    public let title: String
    public let start: Date
    public let end: Date
    public let allDay: Bool
    /// nil means the system default calendar.
    public let calendar: String?
    public let location: String?
    public let notes: String?
    public let url: String?

    public init(
        title: String, start: Date, end: Date, allDay: Bool = false,
        calendar: String? = nil, location: String? = nil, notes: String? = nil,
        url: String? = nil
    ) {
        self.title = title
        self.start = start
        self.end = end
        self.allDay = allDay
        self.calendar = calendar
        self.location = location
        self.notes = notes
        self.url = url
    }
}

/// What calendar_update accepts: a partial change where nil means leave
/// that field alone. Empty location, notes, or url strings clear those
/// fields; moving only the start keeps the event's duration (HC-041).
public struct EventUpdate: Equatable, Sendable {
    public let id: String
    public let title: String?
    public let start: Date?
    public let end: Date?
    public let allDay: Bool?
    public let calendar: String?
    public let location: String?
    public let notes: String?
    public let url: String?

    public init(
        id: String, title: String? = nil, start: Date? = nil, end: Date? = nil,
        allDay: Bool? = nil, calendar: String? = nil, location: String? = nil,
        notes: String? = nil, url: String? = nil
    ) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.allDay = allDay
        self.calendar = calendar
        self.location = location
        self.notes = notes
        self.url = url
    }
}

/// The Calendar domain seam. EKCalendarService is the real one; EventKit
/// cannot attach attendees programmatically, so created events cannot send
/// invitations and nothing here ever leaves the Mac.
public protocol CalendarServicing: Sendable {
    func today(limit: Int) async throws -> [CalendarEvent]
    /// Events inside an explicit window, ascending by start.
    func events(from: Date, to: Date, calendar: String?, limit: Int) async throws -> [CalendarEvent]
    func calendarNames() async throws -> [String]
    func create(_ new: NewEvent) async throws -> CalendarEvent
    /// Touches one occurrence (span this event), not a whole series.
    func update(_ update: EventUpdate) async throws -> CalendarEvent
    /// Returns the deleted event's last snapshot for the audit trail.
    func delete(id: String) async throws -> CalendarEvent
}
