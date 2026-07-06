import Foundation

/// One labeled phone number or email address on a contact card.
public struct LabeledValue: Codable, Equatable, Sendable {
    public let label: String
    public let value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

/// A contact card as the model sees it.
public struct Contact: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let givenName: String
    public let familyName: String
    public let organization: String?
    public let phones: [LabeledValue]
    public let emails: [LabeledValue]

    public init(
        id: String,
        givenName: String,
        familyName: String,
        organization: String?,
        phones: [LabeledValue],
        emails: [LabeledValue]
    ) {
        self.id = id
        self.givenName = givenName
        self.familyName = familyName
        self.organization = organization
        self.phones = phones
        self.emails = emails
    }

    public var fullName: String {
        let name = [givenName, familyName].filter { !$0.isEmpty }.joined(separator: " ")
        if !name.isEmpty { return name }
        return organization ?? "Unknown"
    }
}

/// What contacts_create accepts.
public struct NewContact: Codable, Equatable, Sendable {
    public let givenName: String
    public let familyName: String?
    public let phone: String?
    public let email: String?
    public let organization: String?

    public init(
        givenName: String,
        familyName: String? = nil,
        phone: String? = nil,
        email: String? = nil,
        organization: String? = nil
    ) {
        self.givenName = givenName
        self.familyName = familyName
        self.phone = phone
        self.email = email
        self.organization = organization
    }
}

/// What contacts_update accepts: a partial change where nil means leave
/// that field alone. An empty string clears a field, and a phone or email
/// replaces the whole list with that one value, matching what
/// contacts_create writes (HC-041).
public struct ContactUpdate: Equatable, Sendable {
    public let id: String
    public let givenName: String?
    public let familyName: String?
    public let phone: String?
    public let email: String?
    public let organization: String?

    public init(
        id: String, givenName: String? = nil, familyName: String? = nil,
        phone: String? = nil, email: String? = nil, organization: String? = nil
    ) {
        self.id = id
        self.givenName = givenName
        self.familyName = familyName
        self.phone = phone
        self.email = email
        self.organization = organization
    }
}

/// The Contacts domain seam. CNContactsService is the real one; tests fake it.
public protocol ContactsServicing: Sendable {
    func lookup(query: String, limit: Int) async throws -> [Contact]
    func contact(id: String?, name: String?) async throws -> Contact?
    func create(_ new: NewContact) async throws -> Contact
    func update(_ update: ContactUpdate) async throws -> Contact
    /// Returns the deleted card's last snapshot for the audit trail.
    func delete(id: String) async throws -> Contact
}
