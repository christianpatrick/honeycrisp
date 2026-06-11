import Foundation
import MCP
import Testing
import HoneycrispCore

private actor FakeMessagesService: MessagesServicing {
    private(set) var recents: [(limit: Int, since: Date?, unreadOnly: Bool)] = []
    private(set) var searches:
        [(query: String?, contact: String?, since: Date?, until: Date?, limit: Int)] = []
    private(set) var histories: [(conversation: String, since: Date?, limit: Int)] = []
    private(set) var sends: [(recipient: String, body: String)] = []
    private(set) var marked: [String] = []

    var recentResult: [Conversation] = []
    var searchResult: [MessageHit] = []
    var historyResult: [MessageHit] = []
    var markResult = MarkReadResult(markedRead: true, confirmed: true)

    func setRecentResult(_ conversations: [Conversation]) { recentResult = conversations }
    func setSearchResult(_ hits: [MessageHit]) { searchResult = hits }
    func setHistoryResult(_ hits: [MessageHit]) { historyResult = hits }
    func setMarkResult(_ result: MarkReadResult) { markResult = result }

    func recent(limit: Int, since: Date?, unreadOnly: Bool) async throws -> [Conversation] {
        recents.append((limit, since, unreadOnly))
        return recentResult
    }

    func search(query: String?, contact: String?, since: Date?, until: Date?, limit: Int)
        async throws -> [MessageHit]
    {
        searches.append((query, contact, since, until, limit))
        return searchResult
    }

    func history(conversation: String, since: Date?, limit: Int) async throws -> [MessageHit] {
        histories.append((conversation, since, limit))
        return historyResult
    }

    func send(recipient: String, body: String) async throws -> SendReceipt {
        sends.append((recipient, body))
        return SendReceipt(recipient: recipient, body: body, conversation: "Maya Chen")
    }

    func markRead(conversation: String) async throws -> MarkReadResult {
        marked.append(conversation)
        return markResult
    }
}

private let mayaChat = Conversation(
    id: "iMessage;-;+15551234567",
    name: "+15551234567",
    isGroup: false,
    participants: ["+15551234567"],
    lastMessage: "running 10 min late",
    lastFromMe: false,
    lastAt: Date(timeIntervalSinceReferenceDate: 800_000_000),
    unreadCount: 1
)

@Suite("Messages tools")
struct MessagesToolsTests {
    @Test("recent applies the default limit and passes the new filters")
    func recent() async throws {
        let service = FakeMessagesService()
        await service.setRecentResult([mayaChat])
        let tools = MessagesTools(service: service)
        let outcome = try await tools.execute(action: "recent", arguments: [:], defaultLimit: 12)
        let calls = await service.recents
        #expect(calls.first?.limit == 12)
        #expect(calls.first?.since == nil)
        #expect(calls.first?.unreadOnly == false)
        let decoded = try ToolJSON.decode([Conversation].self, from: outcome.content)
        #expect(decoded == [mayaChat])
        #expect(outcome.auditAction == "Read recent messages")
        #expect(outcome.auditSummary.contains("Nothing was modified"))

        _ = try await tools.execute(
            action: "recent",
            arguments: ["unread_only": true, "since": "2026-06-09T00:00:00"],
            defaultLimit: 12)
        let filtered = await service.recents.last
        #expect(filtered?.unreadOnly == true)
        #expect(filtered?.since != nil)
    }

    @Test("search is filters-first: any one of query, contact, or a time bound works")
    func search() async throws {
        let service = FakeMessagesService()
        await service.setSearchResult([
            MessageHit(
                conversation: "Studio friends",
                conversationId: "iMessage;+;chat123",
                sender: "alex@studio.com",
                text: "lunch friday?",
                at: Date(timeIntervalSinceReferenceDate: 800_000_200))
        ])
        let tools = MessagesTools(service: service)
        let outcome = try await tools.execute(
            action: "search",
            arguments: ["query": "lunch", "contact": "Studio", "limit": 5],
            defaultLimit: 20)
        let calls = await service.searches
        #expect(calls.first?.query == "lunch")
        #expect(calls.first?.contact == "Studio")
        #expect(calls.first?.limit == 5)
        #expect(outcome.auditAction.contains("lunch"))

        _ = try await tools.execute(
            action: "search",
            arguments: ["contact": "Maya", "since": "2026-06-08T00:00:00"],
            defaultLimit: 20)
        let filterOnly = await service.searches.last
        #expect(filterOnly?.query == nil)
        #expect(filterOnly?.since != nil)

        await #expect(throws: ToolFailure.self) {
            _ = try await tools.execute(action: "search", arguments: [:], defaultLimit: 20)
        }
        await #expect(throws: ToolFailure.self) {
            _ = try await tools.execute(
                action: "search", arguments: ["since": "whenever"], defaultLimit: 20)
        }
    }

    @Test("history requires a conversation and reads as a transcript")
    func history() async throws {
        let service = FakeMessagesService()
        await service.setHistoryResult([
            MessageHit(
                conversation: "+15551234567",
                conversationId: "iMessage;-;+15551234567",
                sender: "+15551234567",
                text: "running 10 min late",
                at: Date(timeIntervalSinceReferenceDate: 800_000_000))
        ])
        let tools = MessagesTools(service: service)
        let outcome = try await tools.execute(
            action: "history",
            arguments: ["conversation": "Maya", "since": "2026-06-08T00:00:00", "limit": 50],
            defaultLimit: 20)
        let calls = await service.histories
        #expect(calls.first?.conversation == "Maya")
        #expect(calls.first?.since != nil)
        #expect(calls.first?.limit == 50)
        #expect(outcome.auditAction.contains("Maya"))
        #expect(outcome.auditSummary.contains("Nothing was modified"))

        await #expect(throws: ToolFailure.self) {
            _ = try await tools.execute(action: "history", arguments: [:], defaultLimit: 20)
        }
    }

    @Test("there is no draft action; iMessage cannot draft, only send")
    func noDraft() async {
        let tools = MessagesTools(service: FakeMessagesService())
        await #expect(throws: ToolFailure.self) {
            _ = try await tools.execute(
                action: "draft",
                arguments: ["recipient": "Maya", "body": "hi"],
                defaultLimit: 20)
        }
    }

    @Test("send uses the send audit sentence and passes the body through")
    func send() async throws {
        let service = FakeMessagesService()
        let tools = MessagesTools(service: service)
        let outcome = try await tools.execute(
            action: "send",
            arguments: ["recipient": "+15551234567", "body": "on my way"],
            defaultLimit: 20)
        let sends = await service.sends
        #expect(sends.first?.recipient == "+15551234567")
        #expect(sends.first?.body == "on my way")
        #expect(outcome.auditAction == "Sent a message to +15551234567")
    }

    @Test("send requires recipient and body")
    func sendValidation() async {
        let tools = MessagesTools(service: FakeMessagesService())
        await #expect(throws: ToolFailure.self) {
            _ = try await tools.execute(
                action: "send", arguments: ["recipient": "Maya"], defaultLimit: 20)
        }
        await #expect(throws: ToolFailure.self) {
            _ = try await tools.execute(action: "send", arguments: ["body": "hi"], defaultLimit: 20)
        }
    }

    @Test("mark_read reports confirmation state in the audit copy")
    func markRead() async throws {
        let service = FakeMessagesService()
        await service.setMarkResult(MarkReadResult(markedRead: true, confirmed: false))
        let tools = MessagesTools(service: service)
        let outcome = try await tools.execute(
            action: "mark_read", arguments: ["conversation": "Maya"], defaultLimit: 20)
        #expect(await service.marked == ["Maya"])
        #expect(outcome.auditAction.contains("Maya"))
        #expect(outcome.auditRows.contains(AuditDetailRow(label: "Confirmed", value: "No")))

        await #expect(throws: ToolFailure.self) {
            _ = try await tools.execute(action: "mark_read", arguments: [:], defaultLimit: 20)
        }
    }

    @Test("an unknown messages action fails")
    func unknownAction() async {
        let tools = MessagesTools(service: FakeMessagesService())
        await #expect(throws: ToolFailure.self) {
            _ = try await tools.execute(action: "teleport", arguments: [:], defaultLimit: 20)
        }
    }

    @Test("the executor routes messages when wired")
    func executorRouting() async throws {
        let service = FakeMessagesService()
        await service.setRecentResult([mayaChat])
        let executor = ServiceExecutor(configProvider: { .default }, messages: service)
        let outcome = try await executor.execute(app: .messages, action: "recent", arguments: [:])
        #expect(outcome.content.contains("running 10 min late"))
    }
}
