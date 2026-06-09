import Foundation
import MCP
import Testing
import HoneycrispCore

private actor FakeContactsService: ContactsServicing {
    struct LookupCall: Sendable, Equatable {
        let query: String
        let limit: Int
    }

    private(set) var lookupCalls: [LookupCall] = []
    private(set) var contactCalls: [(id: String?, name: String?)] = []
    private(set) var created: [NewContact] = []

    var lookupResult: [Contact] = []
    var contactResult: Contact?

    func setLookupResult(_ contacts: [Contact]) { lookupResult = contacts }
    func setContactResult(_ contact: Contact?) { contactResult = contact }

    func lookup(query: String, limit: Int) async throws -> [Contact] {
        lookupCalls.append(LookupCall(query: query, limit: limit))
        return lookupResult
    }

    func contact(id: String?, name: String?) async throws -> Contact? {
        contactCalls.append((id, name))
        return contactResult
    }

    func create(_ new: NewContact) async throws -> Contact {
        created.append(new)
        return Contact(
            id: "new-1",
            givenName: new.givenName,
            familyName: new.familyName ?? "",
            organization: new.organization,
            phones: new.phone.map { [LabeledValue(label: "mobile", value: $0)] } ?? [],
            emails: new.email.map { [LabeledValue(label: "home", value: $0)] } ?? []
        )
    }
}

private let maya = Contact(
    id: "c-1",
    givenName: "Maya",
    familyName: "Chen",
    organization: "Studio",
    phones: [LabeledValue(label: "mobile", value: "+15551234567")],
    emails: [LabeledValue(label: "work", value: "maya@studio.com")]
)

private let alex = Contact(
    id: "c-2",
    givenName: "Alex",
    familyName: "Rivera",
    organization: nil,
    phones: [],
    emails: [LabeledValue(label: "home", value: "alex@studio.com")]
)

@Suite("Contacts tools")
struct ContactsToolsTests {
    @Test("lookup passes the query with the config default limit and round-trips JSON")
    func lookup() async throws {
        let service = FakeContactsService()
        await service.setLookupResult([maya, alex])
        let tools = ContactsTools(service: service)
        let outcome = try await tools.execute(
            action: "lookup", arguments: ["query": "studio"], defaultLimit: 20)
        #expect(await service.lookupCalls == [.init(query: "studio", limit: 20)])
        let decoded = try ToolJSON.decode([Contact].self, from: outcome.content)
        #expect(decoded == [maya, alex])
        #expect(outcome.auditSummary.contains("Read 2 contact cards"))
        #expect(outcome.auditAction.contains("studio"))
    }

    @Test("an explicit limit overrides the default")
    func explicitLimit() async throws {
        let service = FakeContactsService()
        let tools = ContactsTools(service: service)
        _ = try await tools.execute(
            action: "lookup", arguments: ["query": "m", "limit": 3], defaultLimit: 20)
        #expect(await service.lookupCalls == [.init(query: "m", limit: 3)])
    }

    @Test("a missing query is a full-sentence failure")
    func missingQuery() async {
        let tools = ContactsTools(service: FakeContactsService())
        await #expect(throws: ToolFailure.self) {
            _ = try await tools.execute(action: "lookup", arguments: [:], defaultLimit: 20)
        }
    }

    @Test("fields by name returns one card with the contact in the audit copy")
    func fieldsByName() async throws {
        let service = FakeContactsService()
        await service.setContactResult(maya)
        let tools = ContactsTools(service: service)
        let outcome = try await tools.execute(
            action: "fields", arguments: ["name": "Maya"], defaultLimit: 20)
        let decoded = try ToolJSON.decode(Contact.self, from: outcome.content)
        #expect(decoded == maya)
        #expect(outcome.auditAction.contains("Maya Chen"))
        #expect(outcome.auditSummary.contains("Nothing was modified"))
    }

    @Test("fields with neither id nor name fails with guidance")
    func fieldsWithoutSelector() async {
        let tools = ContactsTools(service: FakeContactsService())
        await #expect(throws: ToolFailure.self) {
            _ = try await tools.execute(action: "fields", arguments: [:], defaultLimit: 20)
        }
    }

    @Test("fields with no match surfaces the no-match sentence")
    func fieldsNoMatch() async {
        let service = FakeContactsService()
        await service.setContactResult(nil)
        let tools = ContactsTools(service: service)
        do {
            _ = try await tools.execute(
                action: "fields", arguments: ["name": "Nobody"], defaultLimit: 20)
            Issue.record("expected a ToolFailure")
        } catch let failure as ToolFailure {
            #expect(failure.message.contains("Nobody"))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test("create maps every argument onto the new contact")
    func create() async throws {
        let service = FakeContactsService()
        let tools = ContactsTools(service: service)
        let outcome = try await tools.execute(
            action: "create",
            arguments: [
                "given_name": "Maya",
                "family_name": "Chen",
                "phone": "+15551234567",
                "email": "maya@studio.com",
                "organization": "Studio",
            ],
            defaultLimit: 20)
        let created = await service.created
        #expect(created.count == 1)
        #expect(created.first?.givenName == "Maya")
        #expect(created.first?.familyName == "Chen")
        #expect(created.first?.phone == "+15551234567")
        #expect(created.first?.email == "maya@studio.com")
        #expect(created.first?.organization == "Studio")
        #expect(outcome.auditAction.contains("Maya"))
        #expect(outcome.auditSummary.contains("Created one contact"))
    }

    @Test("an unknown contacts action is a failure")
    func unknownAction() async {
        let tools = ContactsTools(service: FakeContactsService())
        await #expect(throws: ToolFailure.self) {
            _ = try await tools.execute(action: "teleport", arguments: [:], defaultLimit: 20)
        }
    }

    @Test("the executor routes contacts and refuses unwired apps clearly")
    func executorRouting() async throws {
        let service = FakeContactsService()
        await service.setLookupResult([maya])
        let executor = ServiceExecutor(
            configProvider: { .default },
            contacts: service
        )
        let outcome = try await executor.execute(
            app: .contacts, action: "lookup", arguments: ["query": "maya"])
        #expect(outcome.content.contains("Maya"))
        do {
            _ = try await executor.execute(app: .reminders, action: "list", arguments: [:])
            Issue.record("expected a ToolFailure for an unwired app")
        } catch let failure as ToolFailure {
            #expect(failure.message.contains("Reminders"))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }
}
