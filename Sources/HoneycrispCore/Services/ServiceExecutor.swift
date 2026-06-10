import Foundation
import MCP

/// Routes gateway calls to the app services. Apps without a wired service
/// fail with a sentence instead of a crash, which also covers builds where
/// a service is deliberately absent.
public struct ServiceExecutor: ToolExecutor {
    private let configProvider: @Sendable () -> HoneycrispConfig
    private let contacts: ContactsTools?
    private let reminders: RemindersTools?
    private let calendar: CalendarTools?
    private let messages: MessagesTools?
    private let mail: MailTools?

    public init(
        configProvider: @escaping @Sendable () -> HoneycrispConfig,
        contacts: (any ContactsServicing)? = nil,
        reminders: (any RemindersServicing)? = nil,
        calendar: (any CalendarServicing)? = nil,
        messages: (any MessagesServicing)? = nil,
        mail: (any MailServicing)? = nil
    ) {
        self.configProvider = configProvider
        self.contacts = contacts.map(ContactsTools.init)
        self.reminders = reminders.map(RemindersTools.init)
        self.calendar = calendar.map(CalendarTools.init)
        self.messages = messages.map(MessagesTools.init)
        self.mail = mail.map(MailTools.init)
    }

    /// The full production wiring with every real service.
    public static func production(configProvider: @escaping @Sendable () -> HoneycrispConfig)
        -> ServiceExecutor
    {
        ServiceExecutor(
            configProvider: configProvider,
            contacts: CNContactsService(),
            reminders: EKRemindersService(),
            calendar: EKCalendarService(),
            messages: MessagesService(),
            mail: MailService()
        )
    }

    public func execute(app: AppID, action: String, arguments: [String: Value]) async throws
        -> ToolOutcome
    {
        let config = configProvider()
        switch app {
        case .contacts:
            guard let contacts else {
                throw ToolFailure("Contacts is not wired up in this build.")
            }
            return try await contacts.execute(
                action: action, arguments: arguments, defaultLimit: config.defaultLimit)
        case .reminders:
            guard let reminders else {
                throw ToolFailure("Reminders is not wired up in this build.")
            }
            return try await reminders.execute(action: action, arguments: arguments, config: config)
        case .calendar:
            guard let calendar else {
                throw ToolFailure("Calendar is not wired up in this build.")
            }
            return try await calendar.execute(
                action: action, arguments: arguments, defaultLimit: config.defaultLimit)
        case .messages:
            guard let messages else {
                throw ToolFailure("Messages is not wired up in this build.")
            }
            return try await messages.execute(
                action: action, arguments: arguments, defaultLimit: config.defaultLimit)
        case .mail:
            guard let mail else {
                throw ToolFailure("Mail is not wired up in this build.")
            }
            return try await mail.execute(
                action: action, arguments: arguments, defaultLimit: config.defaultLimit)
        }
    }
}
