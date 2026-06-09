import Foundation

/// One reminder as the model sees it.
public struct Reminder: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let notes: String?
    public let list: String
    public let dueDate: Date?
    public let completed: Bool

    public init(
        id: String, title: String, notes: String?, list: String, dueDate: Date?, completed: Bool
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.list = list
        self.dueDate = dueDate
        self.completed = completed
    }
}

/// What reminders_create accepts after argument parsing.
public struct NewReminder: Codable, Equatable, Sendable {
    public let title: String
    public let notes: String?
    /// nil means the configured default list, or the system default.
    public let list: String?
    public let dueDate: Date?

    public init(title: String, notes: String? = nil, list: String? = nil, dueDate: Date? = nil) {
        self.title = title
        self.notes = notes
        self.list = list
        self.dueDate = dueDate
    }
}

/// The Reminders domain seam. EKRemindersService is the real one.
public protocol RemindersServicing: Sendable {
    func reminders(list: String?, includeCompleted: Bool, limit: Int) async throws -> [Reminder]
    /// Incomplete reminders due today or overdue.
    func dueToday(limit: Int) async throws -> [Reminder]
    func create(_ new: NewReminder) async throws -> Reminder
    func complete(id: String) async throws -> Reminder
}
