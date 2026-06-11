import Foundation
import MCP

/// Turns reminders tool calls into RemindersServicing calls and service
/// results into JSON plus audit copy.
public struct RemindersTools: Sendable {
    private let service: any RemindersServicing

    public init(service: any RemindersServicing) {
        self.service = service
    }

    public func execute(action: String, arguments: [String: Value], config: HoneycrispConfig)
        async throws -> ToolOutcome
    {
        switch action {
        case "list":
            return try await list(arguments, config: config)
        case "lists":
            return try await listNames()
        case "due":
            return try await due(arguments, config: config)
        case "create":
            return try await create(arguments, config: config)
        case "complete":
            return try await complete(arguments)
        default:
            throw ToolFailure("Reminders cannot do \"\(action)\".")
        }
    }

    private func list(_ arguments: [String: Value], config: HoneycrispConfig) async throws
        -> ToolOutcome
    {
        let list = string(arguments["list"]) ?? config.defaultRemindersList
        let includeCompleted = bool(arguments["include_completed"]) ?? false
        let dueAfter = try dateArg(arguments, "due_after")
        let dueBefore = try dateArg(arguments, "due_before")
        let limit = int(arguments["limit"]) ?? config.defaultLimit
        let found = try await service.reminders(
            list: list, includeCompleted: includeCompleted,
            dueAfter: dueAfter, dueBefore: dueBefore, limit: limit)
        return ToolOutcome(
            content: try ToolJSON.encode(found),
            auditAction: list.map { "Listed the \($0) list" } ?? "Listed reminders",
            auditSummary:
                "Read \(count(found.count, "reminder")). Nothing was modified.",
            auditRows: {
                var rows = [AuditDetailRow(label: "List", value: list ?? "All lists")]
                if let dueAfter {
                    rows.append(
                        AuditDetailRow(label: "Due after", value: ToolDates.rowString(dueAfter)))
                }
                if let dueBefore {
                    rows.append(
                        AuditDetailRow(label: "Due before", value: ToolDates.rowString(dueBefore)))
                }
                rows.append(AuditDetailRow(label: "Returned", value: count(found.count, "reminder")))
                return rows
            }()
        )
    }

    private func listNames() async throws -> ToolOutcome {
        let names = try await service.listNames()
        return ToolOutcome(
            content: try ToolJSON.encode(names),
            auditAction: "Listed the Reminders lists",
            auditSummary: "Read \(names.count) list names. Nothing was modified.",
            auditRows: [
                AuditDetailRow(
                    label: "Returned", value: names.count == 1 ? "1 list" : "\(names.count) lists")
            ]
        )
    }

    private func due(_ arguments: [String: Value], config: HoneycrispConfig) async throws
        -> ToolOutcome
    {
        let limit = int(arguments["limit"]) ?? config.defaultLimit
        let found = try await service.dueToday(limit: limit)
        return ToolOutcome(
            content: try ToolJSON.encode(found),
            auditAction: "Checked what is due today",
            auditSummary:
                "Read \(count(found.count, "reminder")) due today. Nothing was modified.",
            auditRows: [
                AuditDetailRow(label: "List", value: "Today"),
                AuditDetailRow(label: "Returned", value: count(found.count, "reminder")),
                AuditDetailRow(label: "Wrote", value: "Nothing"),
            ]
        )
    }

    private func create(_ arguments: [String: Value], config: HoneycrispConfig) async throws
        -> ToolOutcome
    {
        guard let title = string(arguments["title"]), !title.isEmpty else {
            throw ToolFailure("reminders_create needs a title.")
        }
        var dueDate: Date?
        if let raw = string(arguments["due"]) {
            guard let parsed = ToolDates.parseISO(raw) else {
                throw ToolFailure(
                    "The due date \u{201C}\(raw)\u{201D} did not parse. Send ISO 8601, like 2026-06-12T09:00:00."
                )
            }
            dueDate = parsed
        }
        let new = NewReminder(
            title: title,
            notes: string(arguments["notes"]),
            list: string(arguments["list"]) ?? config.defaultRemindersList,
            dueDate: dueDate
        )
        let created = try await service.create(new)
        var rows = [
            AuditDetailRow(label: "List", value: created.list),
            AuditDetailRow(label: "Created", value: "\u{201C}\(created.title)\u{201D}"),
        ]
        if let dueDate = created.dueDate {
            rows.append(AuditDetailRow(label: "Due", value: ToolDates.rowString(dueDate)))
        }
        return ToolOutcome(
            content: try ToolJSON.encode(created),
            auditAction: "Added \u{201C}\(created.title)\u{201D}",
            auditSummary: "Created one reminder on the \(created.list) list.",
            auditRows: rows
        )
    }

    private func complete(_ arguments: [String: Value]) async throws -> ToolOutcome {
        guard let id = string(arguments["id"]), !id.isEmpty else {
            throw ToolFailure("reminders_complete needs the reminder id.")
        }
        let completed = try await service.complete(id: id)
        return ToolOutcome(
            content: try ToolJSON.encode(completed),
            auditAction: "Marked \u{201C}\(completed.title)\u{201D} as done",
            auditSummary: "Completed one reminder on the \(completed.list) list.",
            auditRows: [
                AuditDetailRow(label: "List", value: completed.list),
                AuditDetailRow(label: "Completed", value: "\u{201C}\(completed.title)\u{201D}"),
            ]
        )
    }

    private func count(_ n: Int, _ noun: String) -> String {
        n == 1 ? "1 \(noun)" : "\(n) \(noun)s"
    }
}
