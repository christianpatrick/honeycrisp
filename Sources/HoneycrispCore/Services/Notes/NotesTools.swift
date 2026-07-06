import Foundation
import MCP

/// Turns notes tool calls into NotesServicing calls and service results
/// into JSON plus audit copy.
public struct NotesTools: Sendable {
    private let service: any NotesServicing

    public init(service: any NotesServicing) {
        self.service = service
    }

    public func execute(action: String, arguments: [String: Value], defaultLimit: Int)
        async throws -> ToolOutcome
    {
        switch action {
        case "search":
            return try await search(arguments, defaultLimit: defaultLimit)
        case "folders":
            return try await folders()
        case "read":
            return try await read(arguments)
        case "link":
            return try await link(arguments)
        case "create":
            return try await create(arguments)
        case "append":
            return try await append(arguments)
        default:
            throw ToolFailure("Notes cannot do \"\(action)\".")
        }
    }

    private func search(_ arguments: [String: Value], defaultLimit: Int) async throws
        -> ToolOutcome
    {
        let query = string(arguments["query"]).flatMap { $0.isEmpty ? nil : $0 }
        let folder = string(arguments["folder"])
        let since = try dateArg(arguments, "since")
        let until = try dateArg(arguments, "until")
        let pinnedOnly = bool(arguments["pinned_only"]) ?? false
        let limit = int(arguments["limit"]) ?? defaultLimit
        let notes = try await service.search(
            query: query, folder: folder, since: since, until: until,
            pinnedOnly: pinnedOnly, limit: limit)
        let noun = notes.count == 1 ? "note" : "notes"
        var rows = [AuditDetailRow(label: "Returned", value: "\(notes.count) \(noun)")]
        if pinnedOnly {
            rows.insert(AuditDetailRow(label: "Filter", value: "Pinned only"), at: 0)
        }
        if let until {
            rows.insert(AuditDetailRow(label: "Until", value: ToolDates.rowString(until)), at: 0)
        }
        if let since {
            rows.insert(AuditDetailRow(label: "Since", value: ToolDates.rowString(since)), at: 0)
        }
        if let folder {
            rows.insert(AuditDetailRow(label: "Folder", value: folder), at: 0)
        }
        if let query {
            rows.insert(AuditDetailRow(label: "Query", value: query), at: 0)
        }
        return ToolOutcome(
            content: try ToolJSON.encode(notes),
            auditAction: query.map { "Searched notes for \u{201C}\($0)\u{201D}" }
                ?? "Searched notes",
            auditSummary: "Read \(notes.count) \(noun). Nothing was modified.",
            auditRows: rows
        )
    }

    private func folders() async throws -> ToolOutcome {
        let folders = try await service.folders()
        return ToolOutcome(
            content: try ToolJSON.encode(folders),
            auditAction: "Listed the Notes folders",
            auditSummary: "Read \(folders.count) folder names. Nothing was modified.",
            auditRows: [
                AuditDetailRow(
                    label: "Returned",
                    value: folders.count == 1 ? "1 folder" : "\(folders.count) folders")
            ]
        )
    }

    private func read(_ arguments: [String: Value]) async throws -> ToolOutcome {
        guard let id = string(arguments["id"]), !id.isEmpty else {
            throw ToolFailure("notes_read needs the note id from notes_search.")
        }
        guard let note = try await service.note(id: id) else {
            throw ToolFailure("No note matched that id. Use the id notes_search returns.")
        }
        return ToolOutcome(
            content: try ToolJSON.encode(note),
            auditAction: "Read the note \u{201C}\(note.title)\u{201D}",
            auditSummary: note.locked
                ? "The note is password protected, so only its details were read. Nothing was modified."
                : "Read one note. Nothing was modified.",
            auditRows: [
                AuditDetailRow(label: "Note", value: note.title),
                AuditDetailRow(label: "Folder", value: note.folder),
            ]
        )
    }

    private func link(_ arguments: [String: Value]) async throws -> ToolOutcome {
        guard let id = string(arguments["id"]), !id.isEmpty else {
            throw ToolFailure("notes_link needs the note id from notes_search.")
        }
        let result = try await service.link(id: id)
        return ToolOutcome(
            content: try ToolJSON.encode(result),
            auditAction: "Copied a link to \u{201C}\(result.title)\u{201D}",
            auditSummary: "Read the note link. Nothing was modified.",
            auditRows: [
                AuditDetailRow(label: "Note", value: result.title),
                AuditDetailRow(label: "Link", value: result.url),
            ]
        )
    }

    private func create(_ arguments: [String: Value]) async throws -> ToolOutcome {
        guard let title = string(arguments["title"]), !title.isEmpty else {
            throw ToolFailure("notes_create needs a title for the note.")
        }
        let body = string(arguments["body"])
        let folder = string(arguments["folder"])
        let receipt = try await service.create(title: title, body: body, folder: folder)
        let destination = receipt.folder.isEmpty ? "your default folder" : receipt.folder
        var rows = [
            AuditDetailRow(label: "Note", value: receipt.title),
            AuditDetailRow(label: "Folder", value: destination),
        ]
        if let url = receipt.url {
            rows.append(AuditDetailRow(label: "Link", value: url))
        }
        return ToolOutcome(
            content: try ToolJSON.encode(receipt),
            auditAction: "Created the note \u{201C}\(receipt.title)\u{201D}",
            auditSummary: "The note was created in \(destination).",
            auditRows: rows
        )
    }

    private func append(_ arguments: [String: Value]) async throws -> ToolOutcome {
        guard let id = string(arguments["id"]), !id.isEmpty else {
            throw ToolFailure("notes_append needs the note id from notes_search.")
        }
        guard let body = string(arguments["body"]), !body.isEmpty else {
            throw ToolFailure("notes_append needs the text to add.")
        }
        let receipt = try await service.append(id: id, body: body)
        let preview = body.count > 60 ? "\(body.prefix(57))..." : body
        return ToolOutcome(
            content: try ToolJSON.encode(receipt),
            auditAction: "Added to the note \u{201C}\(receipt.title)\u{201D}",
            auditSummary: "The text was appended to the end of the note.",
            auditRows: [
                AuditDetailRow(label: "Note", value: receipt.title),
                AuditDetailRow(label: "Added", value: "\u{201C}\(preview)\u{201D}"),
            ]
        )
    }
}
