import Foundation
import MCP
import Testing

import HoneycrispCore

private actor FakeNotesService: NotesServicing {
    private(set) var searches:
        [(query: String?, folder: String?, since: Date?, until: Date?, pinnedOnly: Bool, limit: Int)] = []
    private(set) var folderCalls = 0
    private(set) var reads: [String] = []
    private(set) var links: [String] = []
    private(set) var creates: [(title: String, body: String?, folder: String?)] = []
    private(set) var appends: [(id: String, body: String)] = []

    var searchResult: [NoteSummary] = []
    var noteResult: NoteDetail?

    func setSearchResult(_ notes: [NoteSummary]) { searchResult = notes }
    func setNoteResult(_ note: NoteDetail?) { noteResult = note }

    func search(
        query: String?, folder: String?, since: Date?, until: Date?, pinnedOnly: Bool, limit: Int
    ) async throws -> [NoteSummary] {
        searches.append((query, folder, since, until, pinnedOnly, limit))
        return searchResult
    }

    func folders() async throws -> [NoteFolder] {
        folderCalls += 1
        return [NoteFolder(name: "Recipes", account: "iCloud", notes: 3)]
    }

    func note(id: String) async throws -> NoteDetail? {
        reads.append(id)
        return noteResult
    }

    func link(id: String) async throws -> NoteLinkResult {
        links.append(id)
        return NoteLinkResult(
            id: id, title: "Grocery list", url: "applenotes:note/\(id)",
            accountEmail: "christian@example.com")
    }

    func create(title: String, body: String?, folder: String?) async throws -> NoteCreateReceipt {
        creates.append((title, body, folder))
        return NoteCreateReceipt(
            id: "NEW-UUID", url: "applenotes:note/NEW-UUID", title: title,
            folder: folder ?? "Notes")
    }

    func append(id: String, body: String) async throws -> NoteAppendReceipt {
        appends.append((id, body))
        return NoteAppendReceipt(id: id, title: "Grocery list")
    }
}

private let grocery = NoteSummary(
    id: "AAAAAAAA-1111-2222-3333-444444444444",
    title: "Grocery list",
    snippet: "milk and eggs",
    folder: "Notes",
    account: "iCloud",
    createdAt: Date(timeIntervalSinceReferenceDate: 800_000_000),
    modifiedAt: Date(timeIntervalSinceReferenceDate: 800_000_300),
    pinned: true,
    locked: false,
    shared: false
)

@Suite("Notes tools")
struct NotesToolsTests {
    @Test("search passes filters through and reads as a read in the audit")
    func search() async throws {
        let service = FakeNotesService()
        await service.setSearchResult([grocery])
        let tools = NotesTools(service: service)
        let outcome = try await tools.execute(
            action: "search",
            arguments: [
                "query": .string("grocery"),
                "folder": .string("Notes"),
                "pinned_only": .bool(true),
            ],
            defaultLimit: 15)
        let calls = await service.searches
        #expect(calls.first?.query == "grocery")
        #expect(calls.first?.folder == "Notes")
        #expect(calls.first?.pinnedOnly == true)
        #expect(calls.first?.limit == 15)
        let decoded = try ToolJSON.decode([NoteSummary].self, from: outcome.content)
        #expect(decoded == [grocery])
        #expect(outcome.auditAction == "Searched notes for \u{201C}grocery\u{201D}")
        #expect(outcome.auditSummary.contains("Nothing was modified"))
    }

    @Test("an unparseable date fails with the ISO sentence")
    func badDate() async throws {
        let tools = NotesTools(service: FakeNotesService())
        await #expect(throws: ToolFailure.self) {
            _ = try await tools.execute(
                action: "search", arguments: ["since": .string("last tuesday")], defaultLimit: 5)
        }
    }

    @Test("folders lists names with read-only audit copy")
    func folders() async throws {
        let service = FakeNotesService()
        let tools = NotesTools(service: service)
        let outcome = try await tools.execute(action: "folders", arguments: [:], defaultLimit: 5)
        #expect(await service.folderCalls == 1)
        let decoded = try ToolJSON.decode([NoteFolder].self, from: outcome.content)
        #expect(decoded.map(\.name) == ["Recipes"])
        #expect(outcome.auditAction == "Listed the Notes folders")
        #expect(outcome.auditSummary.contains("Nothing was modified"))
    }

    @Test("read needs the id and returns the full note")
    func read() async throws {
        let service = FakeNotesService()
        await service.setNoteResult(
            NoteDetail(
                id: grocery.id, title: grocery.title, body: "milk\neggs", folder: "Notes",
                account: "iCloud", createdAt: grocery.createdAt, modifiedAt: grocery.modifiedAt,
                pinned: true, locked: false, shared: false))
        let tools = NotesTools(service: service)
        let outcome = try await tools.execute(
            action: "read", arguments: ["id": .string(grocery.id)], defaultLimit: 5)
        #expect(await service.reads == [grocery.id])
        let decoded = try ToolJSON.decode(NoteDetail.self, from: outcome.content)
        #expect(decoded.body == "milk\neggs")
        #expect(outcome.auditAction == "Read the note \u{201C}Grocery list\u{201D}")

        await #expect(throws: ToolFailure.self) {
            _ = try await tools.execute(action: "read", arguments: [:], defaultLimit: 5)
        }
    }

    @Test("an unknown note id reads as a sentence, not a crash")
    func readMissing() async throws {
        let service = FakeNotesService()
        await service.setNoteResult(nil)
        let tools = NotesTools(service: service)
        do {
            _ = try await tools.execute(
                action: "read", arguments: ["id": .string("nope")], defaultLimit: 5)
            Issue.record("expected a ToolFailure")
        } catch let failure as ToolFailure {
            #expect(failure.message.contains("No note matched"))
        }
    }

    @Test("link returns the URL and the account email")
    func link() async throws {
        let service = FakeNotesService()
        let tools = NotesTools(service: service)
        let outcome = try await tools.execute(
            action: "link", arguments: ["id": .string(grocery.id)], defaultLimit: 5)
        #expect(await service.links == [grocery.id])
        let decoded = try ToolJSON.decode(NoteLinkResult.self, from: outcome.content)
        #expect(decoded.url == "applenotes:note/\(grocery.id)")
        #expect(decoded.accountEmail == "christian@example.com")
        #expect(outcome.auditAction == "Copied a link to \u{201C}Grocery list\u{201D}")
        #expect(outcome.auditSummary.contains("Nothing was modified"))
        #expect(outcome.auditRows.contains { $0.value.contains("applenotes:note/") })
    }

    @Test("create needs a title and reports the receipt")
    func create() async throws {
        let service = FakeNotesService()
        let tools = NotesTools(service: service)
        let outcome = try await tools.execute(
            action: "create",
            arguments: [
                "title": .string("Trip plan"),
                "body": .string("Pack the tent"),
                "folder": .string("Travel"),
            ],
            defaultLimit: 5)
        let calls = await service.creates
        #expect(calls.first?.title == "Trip plan")
        #expect(calls.first?.body == "Pack the tent")
        #expect(calls.first?.folder == "Travel")
        let decoded = try ToolJSON.decode(NoteCreateReceipt.self, from: outcome.content)
        #expect(decoded.url == "applenotes:note/NEW-UUID")
        #expect(outcome.auditAction == "Created the note \u{201C}Trip plan\u{201D}")

        await #expect(throws: ToolFailure.self) {
            _ = try await tools.execute(action: "create", arguments: [:], defaultLimit: 5)
        }
    }

    @Test("append needs the id and body and reports what changed")
    func append() async throws {
        let service = FakeNotesService()
        let tools = NotesTools(service: service)
        let outcome = try await tools.execute(
            action: "append",
            arguments: ["id": .string(grocery.id), "body": .string("bread")],
            defaultLimit: 5)
        let calls = await service.appends
        #expect(calls.first?.id == grocery.id)
        #expect(calls.first?.body == "bread")
        #expect(outcome.auditAction == "Added to the note \u{201C}Grocery list\u{201D}")

        await #expect(throws: ToolFailure.self) {
            _ = try await tools.execute(
                action: "append", arguments: ["id": .string(grocery.id)], defaultLimit: 5)
        }
        await #expect(throws: ToolFailure.self) {
            _ = try await tools.execute(
                action: "append", arguments: ["body": .string("bread")], defaultLimit: 5)
        }
    }

    @Test("an unknown action fails with a sentence")
    func unknownAction() async throws {
        let tools = NotesTools(service: FakeNotesService())
        do {
            _ = try await tools.execute(action: "explode", arguments: [:], defaultLimit: 5)
            Issue.record("expected a ToolFailure")
        } catch let failure as ToolFailure {
            #expect(failure.message == "Notes cannot do \"explode\".")
        }
    }
}
