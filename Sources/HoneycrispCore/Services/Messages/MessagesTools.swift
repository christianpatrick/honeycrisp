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
        case "history":
            return try await history(arguments, defaultLimit: defaultLimit)
        case "send":
            return try await send(arguments)
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
        let since = try dateArg(arguments, "since")
        let unreadOnly = bool(arguments["unread_only"]) ?? false
        let conversations = try await service.recent(
            limit: limit, since: since, unreadOnly: unreadOnly)
        let noun = conversations.count == 1 ? "conversation" : "conversations"
        var rows = [AuditDetailRow(label: "Returned", value: "\(conversations.count) \(noun)")]
        if unreadOnly {
            rows.insert(AuditDetailRow(label: "Filter", value: "Unread only"), at: 0)
        }
        if let since {
            rows.insert(
                AuditDetailRow(label: "Since", value: ToolDates.rowString(since)), at: 0)
        }
        return ToolOutcome(
            content: try ToolJSON.encode(conversations),
            auditAction: "Read recent messages",
            auditSummary: "Read \(conversations.count) \(noun). Nothing was modified.",
            auditRows: rows
        )
    }

    private func search(_ arguments: [String: Value], defaultLimit: Int) async throws
        -> ToolOutcome
    {
        let query = string(arguments["query"]).flatMap { $0.isEmpty ? nil : $0 }
        let contact = string(arguments["contact"])
        let since = try dateArg(arguments, "since")
        let until = try dateArg(arguments, "until")
        guard query != nil || contact != nil || since != nil || until != nil else {
            throw ToolFailure(
                "messages_search needs at least one filter: a query, a contact, or a time window."
            )
        }
        let limit = int(arguments["limit"]) ?? defaultLimit
        let hits = try await service.search(
            query: query, contact: contact, since: since, until: until, limit: limit)
        var rows = [AuditDetailRow(label: "Returned", value: "\(hits.count) matches")]
        if let until {
            rows.insert(AuditDetailRow(label: "Until", value: ToolDates.rowString(until)), at: 0)
        }
        if let since {
            rows.insert(AuditDetailRow(label: "Since", value: ToolDates.rowString(since)), at: 0)
        }
        if let contact {
            rows.insert(AuditDetailRow(label: "With", value: contact), at: 0)
        }
        if let query {
            rows.insert(AuditDetailRow(label: "Query", value: query), at: 0)
        }
        return ToolOutcome(
            content: try ToolJSON.encode(hits),
            auditAction: query.map { "Searched Messages for \u{201C}\($0)\u{201D}" }
                ?? "Searched Messages",
            auditSummary: "Read \(hits.count) matches. Nothing was modified.",
            auditRows: rows
        )
    }

    private func history(_ arguments: [String: Value], defaultLimit: Int) async throws
        -> ToolOutcome
    {
        guard let conversation = string(arguments["conversation"]), !conversation.isEmpty else {
            throw ToolFailure(
                "messages_history needs the conversation: a contact name, phone number, or email."
            )
        }
        let since = try dateArg(arguments, "since")
        let limit = int(arguments["limit"]) ?? defaultLimit
        let transcript = try await service.history(
            conversation: conversation, since: since, limit: limit)
        var rows = [
            AuditDetailRow(label: "Conversation", value: conversation),
            AuditDetailRow(label: "Returned", value: "\(transcript.count) messages"),
        ]
        if let since {
            rows.insert(AuditDetailRow(label: "Since", value: ToolDates.rowString(since)), at: 1)
        }
        return ToolOutcome(
            content: try ToolJSON.encode(transcript),
            auditAction: "Read the conversation with \(conversation)",
            auditSummary:
                "Read \(transcript.count) messages from one conversation. Nothing was modified.",
            auditRows: rows
        )
    }

    private func send(_ arguments: [String: Value]) async throws -> ToolOutcome {
        guard let recipient = string(arguments["recipient"]), !recipient.isEmpty else {
            throw ToolFailure(
                "messages_send needs a recipient: a contact name, phone number, or email."
            )
        }
        guard let body = string(arguments["body"]), !body.isEmpty else {
            throw ToolFailure("messages_send needs the message body.")
        }
        let receipt = try await service.send(recipient: recipient, body: body)
        let preview = body.count > 60 ? "\(body.prefix(57))..." : body
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
