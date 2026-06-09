import Foundation
import MCP

/// One catalog action dressed as an MCP tool, plus the copy the approval
/// notification uses for it.
public struct RegisteredTool: Sendable {
    public let descriptor: ActionDescriptor
    public let tool: Tool
    public let approvalSubtitle: String
    let approvalMessage: @Sendable (_ client: String, _ arguments: [String: Value]) -> String

    public func approvalPrompt(client: String, arguments: [String: Value]) -> ApprovalPrompt {
        ApprovalPrompt(
            app: descriptor.app,
            action: descriptor.id,
            client: client,
            message: approvalMessage(client, arguments),
            subtitle: approvalSubtitle
        )
    }
}

/// Maps the sixteen catalog actions to their MCP tools. Tool names are
/// app_action with catalog ids verbatim, like mail_search.
public enum ToolRegistry {
    public static func toolName(for descriptor: ActionDescriptor) -> String {
        "\(descriptor.app.rawValue)_\(descriptor.id)"
    }

    public static func registered(named name: String) -> RegisteredTool? {
        byName[name]
    }

    public static let all: [RegisteredTool] = ActionCatalog.all.map(make)

    private static let byName: [String: RegisteredTool] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.tool.name, $0) })

    // MARK: - Definitions

    private static func make(_ descriptor: ActionDescriptor) -> RegisteredTool {
        let name = toolName(for: descriptor)
        let definition = definitions[name] ?? Definition(
            description: descriptor.label,
            schema: schema(properties: [:])
        )
        let tool = Tool(
            name: name,
            description: definition.description,
            inputSchema: definition.schema,
            annotations: .init(readOnlyHint: descriptor.kind == .read ? true : nil)
        )
        let label = descriptor.label
        return RegisteredTool(
            descriptor: descriptor,
            tool: tool,
            approvalSubtitle: definition.approvalSubtitle,
            approvalMessage: definition.approvalMessage
                ?? { client, _ in "\(client) wants to \(label.lowercased())." }
        )
    }

    private struct Definition {
        let description: String
        let schema: Value
        var approvalSubtitle: String = "This is not auto approved."
        var approvalMessage: (@Sendable (String, [String: Value]) -> String)?
    }

    private static let definitions: [String: Definition] = [
        "mail_search": Definition(
            description:
                "Search Mail for messages matching a query. Returns thread and message summaries with ids you can pass to mail_read.",
            schema: schema(
                properties: [
                    "query": prop("string", "Words to look for in subjects, senders, and bodies."),
                    "mailbox": prop("string", "Limit the search to one mailbox, like Inbox or Sent."),
                    "limit": prop("integer", "The most results to return."),
                ],
                required: ["query"])
        ),
        "mail_read": Definition(
            description: "Read one Mail thread in full, oldest message first.",
            schema: schema(
                properties: [
                    "thread_id": prop("string", "The thread id returned by mail_search."),
                    "limit": prop("integer", "The most messages to return from the thread."),
                ],
                required: ["thread_id"])
        ),
        "mail_draft": Definition(
            description:
                "Create a draft in Mail, optionally as a reply to a message. Nothing is sent.",
            schema: schema(
                properties: [
                    "reply_to_message_id": prop(
                        "string", "Reply to this message id from mail_read."),
                    "to": stringArrayProp("Recipient email addresses."),
                    "cc": stringArrayProp("Cc email addresses."),
                    "subject": prop("string", "The subject line."),
                    "body": prop("string", "The body text of the draft."),
                ],
                required: ["body"])
        ),
        "mail_send": Definition(
            description:
                "Send a mail, either fresh or as a reply. The user approves every send from a notification before it goes out.",
            schema: schema(
                properties: [
                    "reply_to_message_id": prop(
                        "string", "Reply to this message id from mail_read."),
                    "to": stringArrayProp("Recipient email addresses."),
                    "cc": stringArrayProp("Cc email addresses."),
                    "subject": prop("string", "The subject line."),
                    "body": prop("string", "The body text to send."),
                ],
                required: ["body"]),
            approvalSubtitle: "Sending is not auto approved.",
            approvalMessage: { client, arguments in
                let recipients = stringArray(arguments["to"]).joined(separator: ", ")
                return recipients.isEmpty
                    ? "\(client) wants to send a mail."
                    : "\(client) wants to send a mail to \(recipients)."
            }
        ),
        "reminders_list": Definition(
            description:
                "List reminders, optionally from one list, optionally including completed ones.",
            schema: schema(
                properties: [
                    "list": prop("string", "The reminders list to read. Defaults to all lists."),
                    "include_completed": prop("boolean", "Include completed reminders."),
                    "limit": prop("integer", "The most reminders to return."),
                ])
        ),
        "reminders_due": Definition(
            description: "List the reminders due today, including anything overdue.",
            schema: schema(properties: [:])
        ),
        "reminders_create": Definition(
            description:
                "Create a reminder, optionally with an ISO 8601 due date, a list, and notes.",
            schema: schema(
                properties: [
                    "title": prop("string", "What the reminder says."),
                    "due": prop("string", "When it is due, ISO 8601, like 2026-06-12T09:00:00."),
                    "list": prop("string", "The list to put it on. Defaults to the configured list."),
                    "notes": prop("string", "Extra notes on the reminder."),
                ],
                required: ["title"])
        ),
        "reminders_complete": Definition(
            description: "Mark one reminder as done by id.",
            schema: schema(
                properties: [
                    "id": prop("string", "The reminder id from reminders_list or reminders_due."),
                ],
                required: ["id"])
        ),
        "messages_recent": Definition(
            description: "Read the most recent Messages conversations with their latest messages.",
            schema: schema(
                properties: [
                    "limit": prop("integer", "The most conversations to return."),
                ])
        ),
        "messages_search": Definition(
            description: "Search Messages content, optionally narrowed to one contact.",
            schema: schema(
                properties: [
                    "query": prop("string", "Words to look for in message text."),
                    "contact": prop("string", "Only conversations with this contact."),
                    "limit": prop("integer", "The most matches to return."),
                ],
                required: ["query"])
        ),
        "messages_draft": Definition(
            description:
                "Compose a reply in Messages that is sent only after the user approves it from a notification.",
            schema: schema(
                properties: [
                    "recipient": prop("string", "Who to message: a contact name, phone number, or email."),
                    "body": prop("string", "The message text."),
                ],
                required: ["recipient", "body"]),
            approvalSubtitle: "Sending the draft needs your approval.",
            approvalMessage: { client, arguments in
                let recipient = string(arguments["recipient"]) ?? "someone"
                return "\(client) wants to send a reply to \(recipient)."
            }
        ),
        "messages_send": Definition(
            description:
                "Send a message after the user approves it from a notification.",
            schema: schema(
                properties: [
                    "recipient": prop("string", "Who to message: a contact name, phone number, or email."),
                    "body": prop("string", "The message text."),
                ],
                required: ["recipient", "body"]),
            approvalSubtitle: "Sending is not auto approved.",
            approvalMessage: { client, arguments in
                let recipient = string(arguments["recipient"]) ?? "someone"
                return "\(client) wants to send a message to \(recipient)."
            }
        ),
        "messages_mark_read": Definition(
            description:
                "Mark a one on one conversation as read by driving Messages itself, so the change syncs everywhere.",
            schema: schema(
                properties: [
                    "conversation": prop(
                        "string", "The conversation to mark read: a contact name, phone number, or email."),
                ],
                required: ["conversation"])
        ),
        "contacts_lookup": Definition(
            description: "Find people in Contacts by name, email, or phone fragment.",
            schema: schema(
                properties: [
                    "query": prop("string", "A name, email, or phone fragment to look for."),
                    "limit": prop("integer", "The most matches to return."),
                ],
                required: ["query"])
        ),
        "contacts_fields": Definition(
            description: "Read one contact's phone numbers and email addresses.",
            schema: schema(
                properties: [
                    "id": prop("string", "The contact id from contacts_lookup."),
                    "name": prop("string", "Or the contact's name, when you do not have an id."),
                ])
        ),
        "contacts_create": Definition(
            description: "Add a new contact.",
            schema: schema(
                properties: [
                    "given_name": prop("string", "First name."),
                    "family_name": prop("string", "Last name."),
                    "phone": prop("string", "A phone number."),
                    "email": prop("string", "An email address."),
                    "organization": prop("string", "Company or organization."),
                ],
                required: ["given_name"])
        ),
    ]

    // MARK: - Schema helpers

    private static func schema(properties: [String: Value], required: [String] = []) -> Value {
        var object: [String: Value] = [
            "type": .string("object"),
            "properties": .object(properties),
        ]
        if !required.isEmpty {
            object["required"] = .array(required.map { .string($0) })
        }
        return .object(object)
    }

    private static func prop(_ type: String, _ description: String) -> Value {
        .object(["type": .string(type), "description": .string(description)])
    }

    private static func stringArrayProp(_ description: String) -> Value {
        .object([
            "type": .string("array"),
            "items": .object(["type": .string("string")]),
            "description": .string(description),
        ])
    }
}

// MARK: - Value extraction helpers shared by registry and services

func string(_ value: Value?) -> String? {
    if case .string(let result)? = value { return result }
    return nil
}

func stringArray(_ value: Value?) -> [String] {
    guard case .array(let items)? = value else { return [] }
    return items.compactMap {
        if case .string(let result) = $0 { return result }
        return nil
    }
}

func int(_ value: Value?) -> Int? {
    switch value {
    case .int(let result)?: return result
    case .double(let result)?: return Int(result)
    default: return nil
    }
}

func bool(_ value: Value?) -> Bool? {
    if case .bool(let result)? = value { return result }
    return nil
}
