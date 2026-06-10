import Foundation
import MCP

/// Turns calendar tool calls into CalendarServicing calls and service
/// results into JSON plus audit copy.
public struct CalendarTools: Sendable {
    private let service: any CalendarServicing

    public init(service: any CalendarServicing) {
        self.service = service
    }

    public func execute(action: String, arguments: [String: Value], defaultLimit: Int)
        async throws -> ToolOutcome
    {
        switch action {
        case "today":
            return try await today(arguments, defaultLimit: defaultLimit)
        case "list":
            return try await list(arguments, defaultLimit: defaultLimit)
        case "create":
            return try await create(arguments)
        default:
            throw ToolFailure("Calendar cannot do \"\(action)\".")
        }
    }

    private func today(_ arguments: [String: Value], defaultLimit: Int) async throws
        -> ToolOutcome
    {
        let limit = int(arguments["limit"]) ?? defaultLimit
        let events = try await service.today(limit: limit)
        return ToolOutcome(
            content: try ToolJSON.encode(events),
            auditAction: "Checked what is on today",
            auditSummary: "Read \(count(events.count)). Nothing was modified.",
            auditRows: [
                AuditDetailRow(label: "Window", value: "Today"),
                AuditDetailRow(label: "Returned", value: count(events.count)),
            ]
        )
    }

    private func list(_ arguments: [String: Value], defaultLimit: Int) async throws -> ToolOutcome
    {
        let days = min(max(int(arguments["days"]) ?? 7, 1), 365)
        let calendar = string(arguments["calendar"])
        let limit = int(arguments["limit"]) ?? defaultLimit
        let events = try await service.upcoming(days: days, calendar: calendar, limit: limit)
        var rows = [
            AuditDetailRow(label: "Window", value: "Next \(days) day\(days == 1 ? "" : "s")"),
            AuditDetailRow(label: "Returned", value: count(events.count)),
        ]
        if let calendar {
            rows.insert(AuditDetailRow(label: "Calendar", value: calendar), at: 1)
        }
        return ToolOutcome(
            content: try ToolJSON.encode(events),
            auditAction: "Listed the next \(days) day\(days == 1 ? "" : "s")",
            auditSummary: "Read \(count(events.count)). Nothing was modified.",
            auditRows: rows
        )
    }

    private func create(_ arguments: [String: Value]) async throws -> ToolOutcome {
        guard let title = string(arguments["title"]), !title.isEmpty else {
            throw ToolFailure("calendar_create needs a title.")
        }
        guard let rawStart = string(arguments["start"]), let start = ToolDates.parseISO(rawStart)
        else {
            throw ToolFailure(
                "The start \u{201C}\(string(arguments["start"]) ?? "")\u{201D} did not parse. Send ISO 8601, like 2026-06-12T09:00:00."
            )
        }
        var end = start.addingTimeInterval(3600)
        if let rawEnd = string(arguments["end"]) {
            guard let parsed = ToolDates.parseISO(rawEnd) else {
                throw ToolFailure(
                    "The end \u{201C}\(rawEnd)\u{201D} did not parse. Send ISO 8601, like 2026-06-12T10:00:00."
                )
            }
            end = parsed
        }
        let new = NewEvent(
            title: title,
            start: start,
            end: end,
            allDay: bool(arguments["all_day"]) ?? false,
            calendar: string(arguments["calendar"]),
            location: string(arguments["location"]),
            notes: string(arguments["notes"])
        )
        let created = try await service.create(new)
        return ToolOutcome(
            content: try ToolJSON.encode(created),
            auditAction: "Added \u{201C}\(created.title)\u{201D} to Calendar",
            auditSummary: "Created one event on the \(created.calendar) calendar.",
            auditRows: [
                AuditDetailRow(label: "Calendar", value: created.calendar),
                AuditDetailRow(label: "Event", value: "\u{201C}\(created.title)\u{201D}"),
                AuditDetailRow(label: "When", value: ToolDates.rowString(created.start)),
            ]
        )
    }

    private func count(_ n: Int) -> String {
        n == 1 ? "1 event" : "\(n) events"
    }
}
