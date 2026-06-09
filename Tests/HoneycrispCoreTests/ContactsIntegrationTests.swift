import Contacts
import Foundation
import Testing
import HoneycrispCore

/// Real-store tests, opt in because they need a Contacts TCC grant:
/// HONEYCRISP_INTEGRATION=1 swift test
@Suite(
    "Contacts integration",
    .enabled(if: ProcessInfo.processInfo.environment["HONEYCRISP_INTEGRATION"] == "1"))
struct ContactsIntegrationTests {
    @Test("create, lookup, and read fields round trip on the real store")
    func roundTrip() async throws {
        let service = CNContactsService()
        let marker = "Test-\(UUID().uuidString.prefix(8))"
        let created = try await service.create(
            NewContact(
                givenName: "Honeycrisp",
                familyName: marker,
                phone: "+15550100",
                email: "test@honeycrisp.app",
                organization: "Honeycrisp"
            ))
        defer { Self.delete(identifier: created.id) }

        let found = try await service.lookup(query: "Honeycrisp \(marker)", limit: 5)
        #expect(found.contains { $0.id == created.id })

        let card = try await service.contact(id: created.id, name: nil)
        #expect(card?.fullName == "Honeycrisp \(marker)")
        #expect(card?.phones.map(\.value).contains("+15550100") == true)
        #expect(card?.emails.map(\.value).contains("test@honeycrisp.app") == true)
    }

    private static func delete(identifier: String) {
        let store = CNContactStore()
        guard
            let found = try? store.unifiedContact(
                withIdentifier: identifier,
                keysToFetch: [CNContactIdentifierKey as CNKeyDescriptor]),
            let mutable = found.mutableCopy() as? CNMutableContact
        else { return }
        let request = CNSaveRequest()
        request.delete(mutable)
        try? store.execute(request)
    }
}
