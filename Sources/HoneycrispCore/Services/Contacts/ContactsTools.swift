import Foundation
import MCP

/// Turns contacts tool calls into ContactsServicing calls and service
/// results into JSON plus audit copy.
public struct ContactsTools: Sendable {
    private let service: any ContactsServicing

    public init(service: any ContactsServicing) {
        self.service = service
    }

    public func execute(action: String, arguments: [String: Value], defaultLimit: Int)
        async throws -> ToolOutcome
    {
        switch action {
        case "lookup":
            return try await lookup(arguments, defaultLimit: defaultLimit)
        case "fields":
            return try await fields(arguments)
        case "create":
            return try await create(arguments)
        case "update":
            return try await update(arguments)
        case "delete":
            return try await delete(arguments)
        default:
            throw ToolFailure("Contacts cannot do \"\(action)\".")
        }
    }

    private func update(_ arguments: [String: Value]) async throws -> ToolOutcome {
        guard let id = string(arguments["id"]), !id.isEmpty else {
            throw ToolFailure("contacts_update needs the contact id from contacts_lookup.")
        }
        let givenName = string(arguments["given_name"])
        let familyName = string(arguments["family_name"])
        let phone = string(arguments["phone"])
        let email = string(arguments["email"])
        let organization = string(arguments["organization"])
        var changed: [String] = []
        if givenName != nil || familyName != nil { changed.append("name") }
        if phone != nil { changed.append("phone") }
        if email != nil { changed.append("email") }
        if organization != nil { changed.append("organization") }
        guard !changed.isEmpty else {
            throw ToolFailure(
                "contacts_update needs something to change: a name, phone, email, or organization."
            )
        }
        let updated = try await service.update(
            ContactUpdate(
                id: id, givenName: givenName, familyName: familyName,
                phone: phone, email: email, organization: organization))
        return ToolOutcome(
            content: try ToolJSON.encode(updated),
            auditAction: "Updated \u{201C}\(updated.fullName)\u{201D} in Contacts",
            auditSummary: "Changed \(changed.joined(separator: ", ")) on one contact.",
            auditRows: [
                AuditDetailRow(label: "Contact", value: updated.fullName),
                AuditDetailRow(label: "Changed", value: changed.joined(separator: ", ")),
            ]
        )
    }

    private func delete(_ arguments: [String: Value]) async throws -> ToolOutcome {
        guard let id = string(arguments["id"]), !id.isEmpty else {
            throw ToolFailure("contacts_delete needs the contact id from contacts_lookup.")
        }
        let deleted = try await service.delete(id: id)
        return ToolOutcome(
            content: try ToolJSON.encode(deleted),
            auditAction: "Deleted \u{201C}\(deleted.fullName)\u{201D} from Contacts",
            auditSummary: "The contact card was deleted.",
            auditRows: [
                AuditDetailRow(label: "Contact", value: deleted.fullName)
            ]
        )
    }

    private func lookup(_ arguments: [String: Value], defaultLimit: Int) async throws
        -> ToolOutcome
    {
        guard let query = string(arguments["query"]), !query.isEmpty else {
            throw ToolFailure("contacts_lookup needs a query: a name, email, or phone fragment.")
        }
        let limit = int(arguments["limit"]) ?? defaultLimit
        let found = try await service.lookup(query: query, limit: limit)
        let cards = found.count == 1 ? "1 contact card" : "\(found.count) contact cards"
        return ToolOutcome(
            content: try ToolJSON.encode(found),
            auditAction: "Looked up \u{201C}\(query)\u{201D} in Contacts",
            auditSummary: "Read \(cards). Nothing was modified.",
            auditRows: [
                AuditDetailRow(label: "Query", value: query),
                AuditDetailRow(label: "Returned", value: "\(found.count) contacts"),
            ]
        )
    }

    private func fields(_ arguments: [String: Value]) async throws -> ToolOutcome {
        let id = string(arguments["id"])
        let name = string(arguments["name"])
        guard id != nil || name != nil else {
            throw ToolFailure("Give contacts_fields a contact id or a name.")
        }
        guard let found = try await service.contact(id: id, name: name) else {
            throw ToolFailure("No contact matched \u{201C}\(name ?? id ?? "")\u{201D}.")
        }
        return ToolOutcome(
            content: try ToolJSON.encode(found),
            auditAction: "Read \(found.fullName)'s phone and email",
            auditSummary: "Read one contact card. Nothing was modified.",
            auditRows: [
                AuditDetailRow(label: "Contact", value: found.fullName),
                AuditDetailRow(label: "Returned", value: "Phone & email"),
            ]
        )
    }

    private func create(_ arguments: [String: Value]) async throws -> ToolOutcome {
        guard let givenName = string(arguments["given_name"]), !givenName.isEmpty else {
            throw ToolFailure("contacts_create needs at least a given name.")
        }
        let new = NewContact(
            givenName: givenName,
            familyName: string(arguments["family_name"]),
            phone: string(arguments["phone"]),
            email: string(arguments["email"]),
            organization: string(arguments["organization"])
        )
        let created = try await service.create(new)
        var provided = ["name"]
        if new.phone != nil { provided.append("phone") }
        if new.email != nil { provided.append("email") }
        if new.organization != nil { provided.append("organization") }
        return ToolOutcome(
            content: try ToolJSON.encode(created),
            auditAction: "Added \u{201C}\(created.fullName)\u{201D} to Contacts",
            auditSummary: "Created one contact.",
            auditRows: [
                AuditDetailRow(label: "Contact", value: created.fullName),
                AuditDetailRow(label: "Saved", value: provided.joined(separator: ", ")),
            ]
        )
    }
}
