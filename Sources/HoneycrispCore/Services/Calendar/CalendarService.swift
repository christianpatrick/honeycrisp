import Foundation

/// One calendar event as the model sees it.
public struct CalendarEvent: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let calendar: String
    public let start: Date
    public let end: Date
    public let allDay: Bool
    public let location: String?
    public let notes: String?

    public init(
        id: String, title: String, calendar: String, start: Date, end: Date,
        allDay: Bool, location: String?, notes: String?
    ) {
        self.id = id
        self.title = title
        self.calendar = calendar
        self.start = start
        self.end = end
        self.allDay = allDay
        self.location = location
        self.notes = notes
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

    public init(
        title: String, start: Date, end: Date, allDay: Bool = false,
        calendar: String? = nil, location: String? = nil, notes: String? = nil
    ) {
        self.title = title
        self.start = start
        self.end = end
        self.allDay = allDay
        self.calendar = calendar
        self.location = location
        self.notes = notes
    }
}

/// The Calendar domain seam. EKCalendarService is the real one; EventKit
/// cannot attach attendees programmatically, so created events cannot send
/// invitations and nothing here ever leaves the Mac.
public protocol CalendarServicing: Sendable {
    func today(limit: Int) async throws -> [CalendarEvent]
    func upcoming(days: Int, calendar: String?, limit: Int) async throws -> [CalendarEvent]
    func create(_ new: NewEvent) async throws -> CalendarEvent
}
