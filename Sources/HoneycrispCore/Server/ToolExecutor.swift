import Foundation
import MCP

/// What a service hands back from one executed action: the JSON the model
/// sees, plus the audit trail pieces in the service's own words.
public struct ToolOutcome: Sendable, Equatable {
    public let content: String
    public let auditAction: String
    public let auditSummary: String
    public let auditRows: [AuditDetailRow]

    public init(
        content: String,
        auditAction: String,
        auditSummary: String,
        auditRows: [AuditDetailRow] = []
    ) {
        self.content = content
        self.auditAction = auditAction
        self.auditSummary = auditSummary
        self.auditRows = auditRows
    }
}

/// A user-presentable execution failure. The message is shown to the model
/// and recorded in the audit detail, so write it like a sentence.
public struct ToolFailure: Error, Sendable, Equatable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }
}

/// Executes catalog actions. The app services implement this; tests fake it.
public protocol ToolExecutor: Sendable {
    func execute(app: AppID, action: String, arguments: [String: Value]) async throws -> ToolOutcome
}

/// Everything the approval notification needs to render and resolve.
public struct ApprovalPrompt: Sendable, Equatable {
    public let app: AppID
    public let action: String
    public let client: String
    /// The notification body, like "Claude Desktop wants to send a mail to alex@studio.com."
    public let message: String
    /// The smaller line under it, like "Sending is not auto approved."
    public let subtitle: String

    public init(app: AppID, action: String, client: String, message: String, subtitle: String) {
        self.app = app
        self.action = action
        self.client = client
        self.message = message
        self.subtitle = subtitle
    }
}

/// Resolves approval-required actions to a yes or no. The HC-005 broker
/// implements this; a missing broker means approval actions fail closed.
public protocol ApprovalRequesting: Sendable {
    /// Returns true only when the user allowed the action once.
    func requestApproval(_ prompt: ApprovalPrompt) async -> Bool
}

/// What the gateway returns for one tools/call.
public struct GatewayResult: Sendable, Equatable {
    public let content: String
    public let isError: Bool

    public init(content: String, isError: Bool) {
        self.content = content
        self.isError = isError
    }
}
