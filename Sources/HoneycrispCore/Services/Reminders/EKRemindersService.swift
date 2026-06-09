import EventKit
import Foundation

/// The real Reminders service: tier 1 access through EventKit for reads and
/// writes both.
public struct EKRemindersService: RemindersServicing {
    public init() {}

    public func reminders(list: String?, includeCompleted: Bool, limit: Int) async throws
        -> [Reminder]
    {
        let store = try await authorizedStore()
        let calendars = try calendars(matching: list, in: store)
        let predicate = store.predicateForReminders(in: calendars)
        return await fetch(matching: predicate, in: store) { reminders in
            let filtered = reminders.filter { includeCompleted || !$0.isCompleted }
            return Array(Self.sorted(filtered).prefix(max(0, limit))).map(Reminder.init(ek:))
        }
    }

    public func dueToday(limit: Int) async throws -> [Reminder] {
        let store = try await authorizedStore()
        let endOfToday = Calendar.current.startOfDay(for: Date()).addingTimeInterval(24 * 3600)
        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: nil, ending: endOfToday, calendars: nil)
        return await fetch(matching: predicate, in: store) { reminders in
            Array(Self.sorted(reminders).prefix(max(0, limit))).map(Reminder.init(ek:))
        }
    }

    public func create(_ new: NewReminder) async throws -> Reminder {
        let store = try await authorizedStore()
        let reminder = EKReminder(eventStore: store)
        reminder.title = new.title
        reminder.notes = new.notes
        if let list = new.list {
            guard let calendar = try calendars(matching: list, in: store)?.first else {
                throw ToolFailure("There is no Reminders list named \u{201C}\(list)\u{201D}.")
            }
            reminder.calendar = calendar
        } else {
            guard let calendar = store.defaultCalendarForNewReminders() else {
                throw ToolFailure("Reminders has no default list to create into.")
            }
            reminder.calendar = calendar
        }
        if let dueDate = new.dueDate {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: dueDate)
        }
        try store.save(reminder, commit: true)
        return Reminder(ek: reminder)
    }

    public func complete(id: String) async throws -> Reminder {
        let store = try await authorizedStore()
        guard let item = store.calendarItem(withIdentifier: id) as? EKReminder else {
            throw ToolFailure("No reminder matched the id \u{201C}\(id)\u{201D}.")
        }
        item.isCompleted = true
        try store.save(item, commit: true)
        return Reminder(ek: item)
    }

    // MARK: - Plumbing

    private func authorizedStore() async throws -> EKEventStore {
        let store = EKEventStore()
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess, .authorized:
            return store
        case .notDetermined:
            let granted = (try? await store.requestFullAccessToReminders()) ?? false
            guard granted else { throw Self.accessFailure }
            return store
        case .denied, .restricted, .writeOnly:
            throw Self.accessFailure
        @unknown default:
            throw Self.accessFailure
        }
    }

    private static let accessFailure = ToolFailure(
        "Honeycrisp does not have Reminders access. Grant it in System Settings under Privacy & Security, Reminders, then try again."
    )

    /// nil list means all reminder calendars; a name filters case-insensitively.
    private func calendars(matching list: String?, in store: EKEventStore) throws -> [EKCalendar]?
    {
        guard let list else { return nil }
        let matches = store.calendars(for: .reminder).filter {
            $0.title.compare(list, options: .caseInsensitive) == .orderedSame
        }
        guard !matches.isEmpty else {
            throw ToolFailure("There is no Reminders list named \u{201C}\(list)\u{201D}.")
        }
        return matches
    }

    /// EKReminder is not Sendable, so all filtering, sorting, and mapping
    /// happens inside the fetch callback and only Sendable values cross.
    private func fetch(
        matching predicate: NSPredicate,
        in store: EKEventStore,
        transform: @escaping @Sendable ([EKReminder]) -> [Reminder]
    ) async -> [Reminder] {
        await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: transform(reminders ?? []))
            }
        }
    }

    /// Due dates ascending, no due date last, so limits keep actionable items.
    private static func sorted(_ reminders: [EKReminder]) -> [EKReminder] {
        reminders.sorted { lhs, rhs in
            switch (lhs.dueDateComponents?.date, rhs.dueDateComponents?.date) {
            case (nil, nil): return (lhs.title ?? "") < (rhs.title ?? "")
            case (nil, _): return false
            case (_, nil): return true
            case (let left?, let right?): return left < right
            }
        }
    }
}

extension Reminder {
    init(ek reminder: EKReminder) {
        self.init(
            id: reminder.calendarItemIdentifier,
            title: reminder.title ?? "",
            notes: reminder.notes,
            list: reminder.calendar?.title ?? "Reminders",
            dueDate: reminder.dueDateComponents?.date,
            completed: reminder.isCompleted
        )
    }
}
