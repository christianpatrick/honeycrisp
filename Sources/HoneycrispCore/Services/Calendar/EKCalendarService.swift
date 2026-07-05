import EventKit
import Foundation

/// The real Calendar service: tier 1 access through EventKit for reads and
/// writes both. EKEvent objects never cross an isolation boundary; they are
/// mapped to CalendarEvent in the same scope they are fetched.
public struct EKCalendarService: CalendarServicing {
    public init() {}

    public func today(limit: Int) async throws -> [CalendarEvent] {
        let store = try await authorizedStore()
        let start = Calendar.current.startOfDay(for: Date())
        let end = start.addingTimeInterval(24 * 3600)
        return fetch(from: start, to: end, calendars: nil, limit: limit, in: store)
    }

    public func events(from start: Date, to end: Date, calendar: String?, limit: Int)
        async throws -> [CalendarEvent]
    {
        let store = try await authorizedStore()
        let calendars = try calendars(matching: calendar, in: store)
        return fetch(from: start, to: end, calendars: calendars, limit: limit, in: store)
    }

    public func calendarNames() async throws -> [String] {
        let store = try await authorizedStore()
        return store.calendars(for: .event).map(\.title).sorted()
    }

    public func create(_ new: NewEvent) async throws -> CalendarEvent {
        let store = try await authorizedStore()
        let event = EKEvent(eventStore: store)
        event.title = new.title
        event.startDate = new.start
        event.endDate = new.end
        event.isAllDay = new.allDay
        event.location = new.location
        event.notes = new.notes
        if let url = new.url, !url.isEmpty {
            event.url = try Self.parsedURL(url)
        }
        if let name = new.calendar {
            guard let calendar = try calendars(matching: name, in: store)?.first else {
                throw ToolFailure("There is no calendar named \u{201C}\(name)\u{201D}.")
            }
            event.calendar = calendar
        } else {
            guard let calendar = store.defaultCalendarForNewEvents else {
                throw ToolFailure("Calendar has no default calendar to create into.")
            }
            event.calendar = calendar
        }
        try store.save(event, span: .thisEvent)
        return CalendarEvent(ek: event)
    }

    public func update(_ update: EventUpdate) async throws -> CalendarEvent {
        let store = try await authorizedStore()
        let event = try event(id: update.id, in: store)
        if let title = update.title {
            event.title = title
        }
        let window = try Self.resolvedWindow(
            currentStart: event.startDate ?? Date(),
            currentEnd: event.endDate ?? event.startDate ?? Date(),
            newStart: update.start,
            newEnd: update.end)
        event.startDate = window.start
        event.endDate = window.end
        if let allDay = update.allDay {
            event.isAllDay = allDay
        }
        if let name = update.calendar {
            guard let calendar = try calendars(matching: name, in: store)?.first else {
                throw ToolFailure("There is no calendar named \u{201C}\(name)\u{201D}.")
            }
            event.calendar = calendar
        }
        if let location = update.location {
            event.location = location.isEmpty ? nil : location
        }
        if let notes = update.notes {
            event.notes = notes.isEmpty ? nil : notes
        }
        if let url = update.url {
            event.url = url.isEmpty ? nil : try Self.parsedURL(url)
        }
        try store.save(event, span: .thisEvent)
        return CalendarEvent(ek: event)
    }

    private static func parsedURL(_ raw: String) throws -> URL {
        guard let url = URL(string: raw) else {
            throw ToolFailure("\u{201C}\(raw)\u{201D} is not a valid URL.")
        }
        return url
    }

    public func delete(id: String) async throws -> CalendarEvent {
        let store = try await authorizedStore()
        let event = try event(id: id, in: store)
        let snapshot = CalendarEvent(ek: event)
        try store.remove(event, span: .thisEvent)
        return snapshot
    }

    /// The window an update lands on: moving only the start keeps the
    /// event's duration, and an end that does not follow the final start
    /// refuses instead of writing a backwards event.
    static func resolvedWindow(
        currentStart: Date, currentEnd: Date, newStart: Date?, newEnd: Date?
    ) throws -> (start: Date, end: Date) {
        switch (newStart, newEnd) {
        case (nil, nil):
            return (currentStart, currentEnd)
        case (let start?, nil):
            return (start, start.addingTimeInterval(currentEnd.timeIntervalSince(currentStart)))
        case (nil, let end?):
            guard end > currentStart else {
                throw ToolFailure(
                    "The end must come after the start, so nothing was changed.")
            }
            return (currentStart, end)
        case (let start?, let end?):
            guard end > start else {
                throw ToolFailure(
                    "The end must come after the start, so nothing was changed.")
            }
            return (start, end)
        }
    }

    private func event(id: String, in store: EKEventStore) throws -> EKEvent {
        guard let event = store.event(withIdentifier: id) else {
            throw ToolFailure("No event matched the id \u{201C}\(id)\u{201D}.")
        }
        return event
    }

    // MARK: - Plumbing

    private func authorizedStore() async throws -> EKEventStore {
        let store = EKEventStore()
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .authorized:
            return store
        case .notDetermined:
            let granted = (try? await store.requestFullAccessToEvents()) ?? false
            guard granted else { throw Self.accessFailure }
            return store
        case .denied, .restricted, .writeOnly:
            throw Self.accessFailure
        @unknown default:
            throw Self.accessFailure
        }
    }

    private static let accessFailure = ToolFailure(
        "Honeycrisp does not have Calendar access. Grant it in System Settings under Privacy & Security, Calendars, then try again."
    )

    /// nil means all event calendars; a name filters case-insensitively.
    private func calendars(matching name: String?, in store: EKEventStore) throws -> [EKCalendar]?
    {
        guard let name else { return nil }
        let matches = store.calendars(for: .event).filter {
            $0.title.compare(name, options: .caseInsensitive) == .orderedSame
        }
        guard !matches.isEmpty else {
            throw ToolFailure("There is no calendar named \u{201C}\(name)\u{201D}.")
        }
        return matches
    }

    private func fetch(
        from start: Date, to end: Date, calendars: [EKCalendar]?, limit: Int,
        in store: EKEventStore
    ) -> [CalendarEvent] {
        let predicate = store.predicateForEvents(
            withStart: start, end: end, calendars: calendars)
        let events = store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .prefix(max(0, limit))
        return events.map(CalendarEvent.init(ek:))
    }
}

extension CalendarEvent {
    init(ek event: EKEvent) {
        self.init(
            id: event.eventIdentifier ?? event.calendarItemIdentifier,
            title: event.title ?? "",
            calendar: event.calendar?.title ?? "Calendar",
            start: event.startDate ?? Date(),
            end: event.endDate ?? event.startDate ?? Date(),
            allDay: event.isAllDay,
            location: event.location,
            notes: event.notes,
            url: event.url?.absoluteString
        )
    }
}
