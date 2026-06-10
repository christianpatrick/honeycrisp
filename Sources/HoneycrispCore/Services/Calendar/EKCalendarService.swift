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

    public func upcoming(days: Int, calendar: String?, limit: Int) async throws -> [CalendarEvent]
    {
        let store = try await authorizedStore()
        let calendars = try calendars(matching: calendar, in: store)
        let start = Date()
        let end = start.addingTimeInterval(Double(max(1, days)) * 24 * 3600)
        return fetch(from: start, to: end, calendars: calendars, limit: limit, in: store)
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
            notes: event.notes
        )
    }
}
