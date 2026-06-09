import Foundation
import MCP

/// Routes gateway calls to the app services. Apps without a wired service
/// fail with a sentence instead of a crash, which also covers builds where
/// a service is deliberately absent.
public struct ServiceExecutor: ToolExecutor {
    private let configProvider: @Sendable () -> HoneycrispConfig
    private let contacts: ContactsTools?

    public init(
        configProvider: @escaping @Sendable () -> HoneycrispConfig,
        contacts: (any ContactsServicing)? = nil
    ) {
        self.configProvider = configProvider
        self.contacts = contacts.map(ContactsTools.init)
    }

    public func execute(app: AppID, action: String, arguments: [String: Value]) async throws
        -> ToolOutcome
    {
        let defaultLimit = configProvider().defaultLimit
        switch app {
        case .contacts:
            guard let contacts else {
                throw ToolFailure("Contacts is not wired up in this build.")
            }
            return try await contacts.execute(
                action: action, arguments: arguments, defaultLimit: defaultLimit)
        case .reminders:
            throw ToolFailure("Reminders is not wired up in this build.")
        case .messages:
            throw ToolFailure("Messages is not wired up in this build.")
        case .mail:
            throw ToolFailure("Mail is not wired up in this build.")
        }
    }
}
