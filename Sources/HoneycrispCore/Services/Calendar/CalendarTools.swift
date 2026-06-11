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
        case "calendars":
            return try await calendarNames()
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
        let explicitFrom = try dateArg(arguments, "from")
        let explicitTo = try dateArg(arguments, "to")
        let from = explicitFrom ?? Date()
        let to = explicitTo ?? from.addingTimeInterval(Double(days) * 86400)
        let events = try await service.events(from: from, to: to, calendar: calendar, limit: limit)
        let explicitWindow = explicitFrom != nil || explicitTo != nil
        let window =
            explicitWindow
            ? "\(ToolDates.rowString(from)) to \(ToolDates.rowString(to))"
            : "Next \(days) day\(days == 1 ? "" : "s")"
        var rows = [
            AuditDetailRow(label: "Window", value: window),
            AuditDetailRow(label: "Returned", value: count(events.count)),
        ]
        if let calendar {
            rows.insert(AuditDetailRow(label: "Calendar", value: calendar), at: 1)
        }
        return ToolOutcome(
            content: try ToolJSON.encode(events),
            auditAction: explicitWindow
                ? "Listed a date range"
                : "Listed the next \(days) day\(days == 1 ? "" : "s")",
            auditSummary: "Read \(count(events.count)). Nothing was modified.",
            auditRows: rows
        )
    }

    private func calendarNames() async throws -> ToolOutcome {
        let names = try await service.calendarNames()
        return ToolOutcome(
            content: try ToolJSON.encode(names),
            auditAction: "Listed the calendars",
            auditSummary: "Read \(names.count) calendar names. Nothing was modified.",
            auditRows: [
                AuditDetailRow(
                    label: "Returned",
                    value: names.count == 1 ? "1 calendar" : "\(names.count) calendars")
            ]
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
