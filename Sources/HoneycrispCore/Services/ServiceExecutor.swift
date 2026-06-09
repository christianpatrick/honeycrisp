import Foundation
import MCP

/// Routes gateway calls to the app services. Apps without a wired service
/// fail with a sentence instead of a crash, which also covers builds where
/// a service is deliberately absent.
public struct ServiceExecutor: ToolExecutor {
    private let configProvider: @Sendable () -> HoneycrispConfig
    private let contacts: ContactsTools?
    private let reminders: RemindersTools?

    public init(
        configProvider: @escaping @Sendable () -> HoneycrispConfig,
        contacts: (any ContactsServicing)? = nil,
        reminders: (any RemindersServicing)? = nil
    ) {
        self.configProvider = configProvider
        self.contacts = contacts.map(ContactsTools.init)
        self.reminders = reminders.map(RemindersTools.init)
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
        case .messages:
            throw ToolFailure("Messages is not wired up in this build.")
        case .mail:
            throw ToolFailure("Mail is not wired up in this build.")
        }
    }
}
