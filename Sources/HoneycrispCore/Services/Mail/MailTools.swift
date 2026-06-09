import Foundation
import MCP

/// Turns mail tool calls into MailServicing calls and service results into
/// JSON plus audit copy in the mock's voice.
public struct MailTools: Sendable {
    private let service: any MailServicing

    public init(service: any MailServicing) {
        self.service = service
    }

    public func execute(action: String, arguments: [String: Value], defaultLimit: Int)
        async throws -> ToolOutcome
    {
        switch action {
        case "search":
            return try await search(arguments, defaultLimit: defaultLimit)
        case "read":
            return try await read(arguments, defaultLimit: defaultLimit)
        case "draft":
            return try await compose(arguments, send: false)
        case "send":
            return try await compose(arguments, send: true)
        case "mark_read":
            return try await markRead(arguments, defaultLimit: defaultLimit)
        default:
            throw ToolFailure("Mail cannot do \"\(action)\".")
        }
    }

    private func markRead(_ arguments: [String: Value], defaultLimit: Int) async throws
        -> ToolOutcome
    {
        let messageID = string(arguments["message_id"])
        let threadID = string(arguments["thread_id"])
        let ids: [String]
        let what: String
        if let messageID, !messageID.isEmpty {
            ids = [messageID]
            what = "the message"
        } else if let threadID, !threadID.isEmpty {
            let thread = try await service.thread(id: threadID, limit: max(defaultLimit, 100))
            ids = thread.messages.map(\.id)
            what = "the thread \u{201C}\(thread.subject)\u{201D}"
        } else {
            throw ToolFailure(
                "mail_mark_read needs a message_id from mail_search, or a thread_id to mark the whole conversation."
            )
        }
        let marked = try await service.markRead(messageIDs: ids)
        return ToolOutcome(
            content: try ToolJSON.encode(["marked": marked]),
            auditAction: "Marked \(what) as read",
            auditSummary:
                "Updated read status on \(marked) message\(marked == 1 ? "" : "s"). Mail syncs the change to your mail server.",
            auditRows: [
                AuditDetailRow(label: "Marked", value: "\(marked) message\(marked == 1 ? "" : "s")")
            ]
        )
    }

    private func search(_ arguments: [String: Value], defaultLimit: Int) async throws
        -> ToolOutcome
    {
        guard let query = string(arguments["query"]), !query.isEmpty else {
            throw ToolFailure("mail_search needs a query.")
        }
        let mailbox = string(arguments["mailbox"])
        let limit = int(arguments["limit"]) ?? defaultLimit
        let found = try await service.search(query: query, mailbox: mailbox, limit: limit)
        var rows = [
            AuditDetailRow(label: "Query", value: query),
            AuditDetailRow(label: "Returned", value: "\(found.count) messages"),
        ]
        if let mailbox {
            rows.insert(AuditDetailRow(label: "Mailbox", value: mailbox), at: 0)
        } else {
            rows.insert(AuditDetailRow(label: "Mailbox", value: "All Inboxes"), at: 0)
        }
        return ToolOutcome(
            content: try ToolJSON.encode(found),
            auditAction: "Searched Mail for \u{201C}\(query)\u{201D}",
            auditSummary: "Read \(found.count) message summaries. Nothing was modified.",
            auditRows: rows
        )
    }

    private func read(_ arguments: [String: Value], defaultLimit: Int) async throws -> ToolOutcome
    {
        guard let threadID = string(arguments["thread_id"]), !threadID.isEmpty else {
            throw ToolFailure("mail_read needs the thread_id from mail_search.")
        }
        let limit = int(arguments["limit"]) ?? defaultLimit
        let thread = try await service.thread(id: threadID, limit: limit)
        let with = thread.participants.prefix(3).joined(separator: ", ")
        let more = thread.participants.count > 3 ? ", +\(thread.participants.count - 3)" : ""
        return ToolOutcome(
            content: try ToolJSON.encode(thread),
            auditAction: "Read the thread \u{201C}\(thread.subject)\u{201D}",
            auditSummary:
                "Returned the subject and \(thread.messages.count) message bodies. Nothing was modified.",
            auditRows: [
                AuditDetailRow(label: "Thread", value: thread.subject),
                AuditDetailRow(label: "With", value: with + more),
                AuditDetailRow(
                    label: "Returned", value: "Subject, \(thread.messages.count) message bodies"),
            ]
        )
    }

    private func compose(_ arguments: [String: Value], send: Bool) async throws -> ToolOutcome {
        let verb = send ? "send" : "draft"
        guard let body = string(arguments["body"]), !body.isEmpty else {
            throw ToolFailure("mail_\(verb) needs the body text.")
        }
        var to = stringArray(arguments["to"])
        var subject = string(arguments["subject"])
        var replyName: String?

        if let replyID = string(arguments["reply_to_message_id"]) {
            guard let original = try await service.messageSummary(id: replyID) else {
                throw ToolFailure("No message matched the id \u{201C}\(replyID)\u{201D}.")
            }
            replyName = original.fromName ?? original.from
            if to.isEmpty { to = [original.from] }
            if subject == nil {
                subject =
                    original.subject.lowercased().hasPrefix("re:")
                    ? original.subject : "Re: \(original.subject)"
            }
        }
        guard !to.isEmpty else {
            throw ToolFailure(
                "mail_\(verb) needs recipients: pass to addresses or a reply_to_message_id.")
        }
        let draft = MailDraft(to: to, cc: stringArray(arguments["cc"]), subject: subject, body: body)
        let receipt = send ? try await service.send(draft) : try await service.draft(draft)

        let who = replyName ?? to.joined(separator: ", ")
        var rows = [
            AuditDetailRow(label: "To", value: to.joined(separator: ", "))
        ]
        if let subject {
            rows.append(AuditDetailRow(label: "Subject", value: subject))
        }
        if send {
            rows.append(AuditDetailRow(label: "Sent", value: "Yes, after approval"))
            return ToolOutcome(
                content: try ToolJSON.encode(receipt),
                auditAction: "Sent a mail to \(who)",
                auditSummary: "The mail was sent after you approved it.",
                auditRows: rows
            )
        }
        rows.append(AuditDetailRow(label: "Saved", value: "Drafts mailbox"))
        return ToolOutcome(
            content: try ToolJSON.encode(receipt),
            auditAction: replyName.map { "Drafted a reply to \($0)" }
                ?? "Drafted a mail to \(who)",
            auditSummary: "Saved a draft in Mail. Nothing was sent.",
            auditRows: rows
        )
    }
}
