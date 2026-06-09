import Contacts
import Foundation

/// The real Contacts service: tier 1 access through the Contacts framework
/// for reads and writes both. No Apple events anywhere near this file.
public struct CNContactsService: ContactsServicing {
    public init() {}

    // Computed, not stored: CNKeyDescriptor is not Sendable, so a shared
    // static array trips strict concurrency.
    private static var keys: [CNKeyDescriptor] {
        [
            CNContactIdentifierKey, CNContactGivenNameKey, CNContactFamilyNameKey,
            CNContactOrganizationNameKey, CNContactPhoneNumbersKey, CNContactEmailAddressesKey,
        ] as [CNKeyDescriptor]
    }

    public func lookup(query: String, limit: Int) async throws -> [Contact] {
        let store = try await authorizedStore()
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let predicate: NSPredicate
        if trimmed.contains("@") {
            predicate = CNContact.predicateForContacts(matchingEmailAddress: trimmed)
        } else if trimmed.filter(\.isNumber).count >= max(3, trimmed.count / 2) {
            predicate = CNContact.predicateForContacts(
                matching: CNPhoneNumber(stringValue: trimmed))
        } else {
            predicate = CNContact.predicateForContacts(matchingName: trimmed)
        }
        let found = try store.unifiedContacts(matching: predicate, keysToFetch: Self.keys)
        return found.prefix(max(0, limit)).map(Contact.init(cn:))
    }

    public func contact(id: String?, name: String?) async throws -> Contact? {
        if let id {
            let store = try await authorizedStore()
            guard
                let found = try? store.unifiedContact(withIdentifier: id, keysToFetch: Self.keys)
            else { return nil }
            return Contact(cn: found)
        }
        guard let name else { return nil }
        return try await lookup(query: name, limit: 1).first
    }

    public func create(_ new: NewContact) async throws -> Contact {
        let store = try await authorizedStore()
        let cn = CNMutableContact()
        cn.givenName = new.givenName
        if let familyName = new.familyName { cn.familyName = familyName }
        if let organization = new.organization { cn.organizationName = organization }
        if let phone = new.phone {
            cn.phoneNumbers = [
                CNLabeledValue(
                    label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: phone))
            ]
        }
        if let email = new.email {
            cn.emailAddresses = [CNLabeledValue(label: CNLabelHome, value: email as NSString)]
        }
        let request = CNSaveRequest()
        request.add(cn, toContainerWithIdentifier: nil)
        try store.execute(request)
        return Contact(cn: cn)
    }

    private func authorizedStore() async throws -> CNContactStore {
        let store = CNContactStore()
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized, .limited:
            return store
        case .notDetermined:
            let granted = (try? await store.requestAccess(for: .contacts)) ?? false
            guard granted else { throw Self.accessFailure }
            return store
        case .denied, .restricted:
            throw Self.accessFailure
        @unknown default:
            throw Self.accessFailure
        }
    }

    private static let accessFailure = ToolFailure(
        "Honeycrisp does not have Contacts access. Grant it in System Settings under Privacy & Security, Contacts, then try again."
    )
}

extension Contact {
    init(cn: CNContact) {
        self.init(
            id: cn.identifier,
            givenName: cn.givenName,
            familyName: cn.familyName,
            organization: cn.organizationName.isEmpty ? nil : cn.organizationName,
            phones: cn.phoneNumbers.map {
                LabeledValue(label: Contact.cleanLabel($0.label), value: $0.value.stringValue)
            },
            emails: cn.emailAddresses.map {
                LabeledValue(label: Contact.cleanLabel($0.label), value: $0.value as String)
            }
        )
    }

    private static func cleanLabel(_ label: String?) -> String {
        guard let label, !label.isEmpty else { return "other" }
        return CNLabeledValue<NSString>.localizedString(forLabel: label)
    }
}
