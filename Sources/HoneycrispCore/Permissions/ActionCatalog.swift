import Foundation

/// The four Apple apps Honeycrisp can reach.
public enum AppID: String, CaseIterable, Codable, Sendable, Hashable {
    case mail
    case reminders
    case calendar
    case messages
    case contacts
}

extension AppID: CodingKeyRepresentable {}

/// Whether an action only looks at data or mutates something.
public enum ActionKind: String, Codable, Sendable, Equatable {
    case read
    case write
}

/// Display data for one app, straight from the catalog spec.
public struct AppDescriptor: Sendable, Equatable {
    public let id: AppID
    public let name: String
    public let blurb: String
}

/// One action an assistant can take, with its permission semantics.
public struct ActionDescriptor: Sendable, Equatable {
    public let app: AppID
    public let id: String
    public let label: String
    public let kind: ActionKind
    /// Whether the switch ships on in a fresh config.
    public let defaultOn: Bool
    /// True for writes whose effect leaves the Mac; these always post an
    /// approval notification even when their switch is on.
    public let requiresApproval: Bool
}

/// The source of truth for what Honeycrisp can do, mirrored one to one from
/// .spec/HC-002-permission-engine.md and the catalog spec.
public enum ActionCatalog {
    public static let apps: [AppDescriptor] = [
        AppDescriptor(id: .mail, name: "Mail", blurb: "Search, read, and draft mail."),
        AppDescriptor(id: .reminders, name: "Reminders", blurb: "See what is due and add new ones."),
        AppDescriptor(id: .calendar, name: "Calendar", blurb: "See your schedule and add events."),
        AppDescriptor(id: .messages, name: "Messages", blurb: "Read recent texts and send replies."),
        AppDescriptor(id: .contacts, name: "Contacts", blurb: "Look up people you know."),
    ]

    public static let all: [ActionDescriptor] = [
        ActionDescriptor(app: .mail, id: "search", label: "Search mailboxes", kind: .read, defaultOn: true, requiresApproval: false),
        ActionDescriptor(app: .mail, id: "read", label: "Read a thread", kind: .read, defaultOn: true, requiresApproval: false),
        ActionDescriptor(app: .mail, id: "draft", label: "Draft a reply", kind: .write, defaultOn: true, requiresApproval: false),
        ActionDescriptor(app: .mail, id: "send", label: "Send mail", kind: .write, defaultOn: false, requiresApproval: true),
        ActionDescriptor(app: .mail, id: "mark_read", label: "Mark as read", kind: .write, defaultOn: false, requiresApproval: false),
        ActionDescriptor(app: .reminders, id: "list", label: "List reminders", kind: .read, defaultOn: true, requiresApproval: false),
        ActionDescriptor(app: .reminders, id: "due", label: "Check what is due today", kind: .read, defaultOn: true, requiresApproval: false),
        ActionDescriptor(app: .reminders, id: "create", label: "Create a reminder", kind: .write, defaultOn: true, requiresApproval: false),
        ActionDescriptor(app: .reminders, id: "complete", label: "Mark as done", kind: .write, defaultOn: true, requiresApproval: false),
        ActionDescriptor(app: .calendar, id: "today", label: "Check what is on today", kind: .read, defaultOn: true, requiresApproval: false),
        ActionDescriptor(app: .calendar, id: "list", label: "List upcoming events", kind: .read, defaultOn: true, requiresApproval: false),
        ActionDescriptor(app: .calendar, id: "create", label: "Create an event", kind: .write, defaultOn: false, requiresApproval: false),
        ActionDescriptor(app: .messages, id: "recent", label: "Read recent messages", kind: .read, defaultOn: true, requiresApproval: false),
        ActionDescriptor(app: .messages, id: "search", label: "Search conversations", kind: .read, defaultOn: true, requiresApproval: false),
        ActionDescriptor(app: .messages, id: "send", label: "Send a message", kind: .write, defaultOn: false, requiresApproval: true),
        ActionDescriptor(app: .messages, id: "mark_read", label: "Mark a conversation read", kind: .write, defaultOn: false, requiresApproval: false),
        ActionDescriptor(app: .contacts, id: "lookup", label: "Look up a contact", kind: .read, defaultOn: true, requiresApproval: false),
        ActionDescriptor(app: .contacts, id: "fields", label: "Read phone & email", kind: .read, defaultOn: true, requiresApproval: false),
        ActionDescriptor(app: .contacts, id: "create", label: "Add a contact", kind: .write, defaultOn: false, requiresApproval: false),
    ]

    public static func actions(for app: AppID) -> [ActionDescriptor] {
        all.filter { $0.app == app }
    }

    public static func descriptor(app: AppID, action id: String) -> ActionDescriptor? {
        all.first { $0.app == app && $0.id == id }
    }
}
