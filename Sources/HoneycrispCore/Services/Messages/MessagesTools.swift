import Foundation
import MCP

/// Turns messages tool calls into MessagesServicing calls and service
/// results into JSON plus audit copy. Draft and send both end in a send;
/// the gateway already ran their approval, so here they differ only in how
/// the audit reads.
public struct MessagesTools: Sendable {
    private let service: any MessagesServicing

    public init(service: any MessagesServicing) {
        self.service = service
    }

    public func execute(action: String, arguments: [String: Value], defaultLimit: Int)
        async throws -> ToolOutcome
    {
        switch action {
        case "recent":
            return try await recent(arguments, defaultLimit: defaultLimit)
        case "search":
            return try await search(arguments, defaultLimit: defaultLimit)
        case "draft":
            return try await send(arguments, asDraft: true)
        case "send":
            return try await send(arguments, asDraft: false)
        case "mark_read":
            return try await markRead(arguments)
        default:
            throw ToolFailure("Messages cannot do \"\(action)\".")
        }
    }

    private func recent(_ arguments: [String: Value], defaultLimit: Int) async throws
        -> ToolOutcome
    {
        let limit = int(arguments["limit"]) ?? defaultLimit
        let conversations = try await service.recent(limit: limit)
        let noun = conversations.count == 1 ? "conversation" : "conversations"
        return ToolOutcome(
            content: try ToolJSON.encode(conversations),
            auditAction: "Read recent messages",
            auditSummary: "Read \(conversations.count) \(noun). Nothing was modified.",
            auditRows: [
                AuditDetailRow(label: "Returned", value: "\(conversations.count) \(noun)")
            ]
        )
    }

    private func search(_ arguments: [String: Value], defaultLimit: Int) async throws
        -> ToolOutcome
    {
        guard let query = string(arguments["query"]), !query.isEmpty else {
            throw ToolFailure("messages_search needs a query.")
        }
        let contact = string(arguments["contact"])
        let limit = int(arguments["limit"]) ?? defaultLimit
        let hits = try await service.search(query: query, contact: contact, limit: limit)
        var rows = [
            AuditDetailRow(label: "Query", value: query),
            AuditDetailRow(label: "Returned", value: "\(hits.count) matches"),
        ]
        if let contact {
            rows.insert(AuditDetailRow(label: "With", value: contact), at: 1)
        }
        return ToolOutcome(
            content: try ToolJSON.encode(hits),
            auditAction: "Searched Messages for \u{201C}\(query)\u{201D}",
            auditSummary: "Read \(hits.count) matches. Nothing was modified.",
            auditRows: rows
        )
    }

    private func send(_ arguments: [String: Value], asDraft: Bool) async throws -> ToolOutcome {
        guard let recipient = string(arguments["recipient"]), !recipient.isEmpty else {
            throw ToolFailure(
                "messages_\(asDraft ? "draft" : "send") needs a recipient: a contact name, phone number, or email."
            )
        }
        guard let body = string(arguments["body"]), !body.isEmpty else {
            throw ToolFailure("messages_\(asDraft ? "draft" : "send") needs the message body.")
        }
        let receipt = try await service.send(recipient: recipient, body: body)
        let preview = body.count > 60 ? "\(body.prefix(57))..." : body
        if asDraft {
            return ToolOutcome(
                content: try ToolJSON.encode(receipt),
                auditAction: "Drafted a reply to \(recipient)",
                auditSummary: "The draft was sent after you approved it.",
                auditRows: [
                    AuditDetailRow(label: "To", value: receipt.conversation),
                    AuditDetailRow(label: "Draft", value: "\u{201C}\(preview)\u{201D}"),
                    AuditDetailRow(label: "Sent", value: "Yes, after approval"),
                ]
            )
        }
        return ToolOutcome(
            content: try ToolJSON.encode(receipt),
            auditAction: "Sent a message to \(recipient)",
            auditSummary: "The message was sent after you approved it.",
            auditRows: [
                AuditDetailRow(label: "To", value: receipt.conversation),
                AuditDetailRow(label: "Message", value: "\u{201C}\(preview)\u{201D}"),
            ]
        )
    }

    private func markRead(_ arguments: [String: Value]) async throws -> ToolOutcome {
        guard let conversation = string(arguments["conversation"]), !conversation.isEmpty else {
            throw ToolFailure(
                "messages_mark_read needs the conversation: a contact name, phone number, or email."
            )
        }
        let result = try await service.markRead(conversation: conversation)
        return ToolOutcome(
            content: try ToolJSON.encode(result),
            auditAction: "Marked the conversation with \(conversation) as read",
            auditSummary: result.confirmed
                ? "Messages confirmed the conversation is read everywhere."
                : "Messages was asked to mark it read, but the change was not confirmed.",
            auditRows: [
                AuditDetailRow(label: "Conversation", value: conversation),
                AuditDetailRow(label: "Confirmed", value: result.confirmed ? "Yes" : "No"),
            ]
        )
    }
}
