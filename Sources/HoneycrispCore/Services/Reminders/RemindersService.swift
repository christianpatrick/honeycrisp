import Foundation

/// One reminder as the model sees it. The url is the EventKit URL field;
/// some Reminders versions do not display it in the app, so links that
/// must be visible belong in notes too.
public struct Reminder: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let notes: String?
    public let list: String
    public let dueDate: Date?
    public let completed: Bool
    public let url: String?

    public init(
        id: String, title: String, notes: String?, list: String, dueDate: Date?,
        completed: Bool, url: String? = nil
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.list = list
        self.dueDate = dueDate
        self.completed = completed
        self.url = url
    }
}

/// What reminders_create accepts after argument parsing.
public struct NewReminder: Codable, Equatable, Sendable {
    public let title: String
    public let notes: String?
    /// nil means the configured default list, or the system default.
    public let list: String?
    public let dueDate: Date?
    public let url: String?

    public init(
        title: String, notes: String? = nil, list: String? = nil, dueDate: Date? = nil,
        url: String? = nil
    ) {
        self.title = title
        self.notes = notes
        self.list = list
        self.dueDate = dueDate
        self.url = url
    }
}

/// What reminders_update accepts: a partial change where nil means leave
/// that field alone. Empty notes or url strings clear those fields;
/// clearDue removes the due date (HC-041).
public struct ReminderUpdate: Equatable, Sendable {
    public let id: String
    public let title: String?
    public let notes: String?
    public let list: String?
    public let dueDate: Date?
    public let clearDue: Bool
    public let completed: Bool?
    public let url: String?

    public init(
        id: String, title: String? = nil, notes: String? = nil, list: String? = nil,
        dueDate: Date? = nil, clearDue: Bool = false, completed: Bool? = nil,
        url: String? = nil
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.list = list
        self.dueDate = dueDate
        self.clearDue = clearDue
        self.completed = completed
        self.url = url
    }
}

/// The Reminders domain seam. EKRemindersService is the real one.
public protocol RemindersServicing: Sendable {
    /// A due window excludes reminders without a due date: a window is a
    /// question about dates.
    func reminders(
        list: String?, includeCompleted: Bool, dueAfter: Date?, dueBefore: Date?, limit: Int
    ) async throws -> [Reminder]
    func listNames() async throws -> [String]
    /// Incomplete reminders due today or overdue.
    func dueToday(limit: Int) async throws -> [Reminder]
    func create(_ new: NewReminder) async throws -> Reminder
    func complete(id: String) async throws -> Reminder
    func update(_ update: ReminderUpdate) async throws -> Reminder
    /// Returns the deleted reminder's last snapshot for the audit trail.
    func delete(id: String) async throws -> Reminder
}
