import Foundation
import MCP
import Testing
import HoneycrispCore

private actor FakeMessagesService: MessagesServicing {
    private(set) var recentLimits: [Int] = []
    private(set) var searches: [(query: String, contact: String?, limit: Int)] = []
    private(set) var sends: [(recipient: String, body: String)] = []
    private(set) var marked: [String] = []

    var recentResult: [Conversation] = []
    var searchResult: [MessageHit] = []
    var markResult = MarkReadResult(markedRead: true, confirmed: true)

    func setRecentResult(_ conversations: [Conversation]) { recentResult = conversations }
    func setSearchResult(_ hits: [MessageHit]) { searchResult = hits }
    func setMarkResult(_ result: MarkReadResult) { markResult = result }

    func recent(limit: Int) async throws -> [Conversation] {
        recentLimits.append(limit)
        return recentResult
    }

    func search(query: String, contact: String?, limit: Int) async throws -> [MessageHit] {
        searches.append((query, contact, limit))
        return searchResult
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
    @Test("recent applies the default limit and round-trips JSON")
    func recent() async throws {
        let service = FakeMessagesService()
        await service.setRecentResult([mayaChat])
        let tools = MessagesTools(service: service)
        let outcome = try await tools.execute(action: "recent", arguments: [:], defaultLimit: 12)
        #expect(await service.recentLimits == [12])
        let decoded = try ToolJSON.decode([Conversation].self, from: outcome.content)
        #expect(decoded == [mayaChat])
        #expect(outcome.auditAction == "Read recent messages")
        #expect(outcome.auditSummary.contains("Nothing was modified"))
    }

    @Test("search requires a query and passes the contact filter")
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
        #expect(calls.count == 1)
        #expect(calls.first?.query == "lunch")
        #expect(calls.first?.contact == "Studio")
        #expect(calls.first?.limit == 5)
        #expect(outcome.auditAction.contains("lunch"))

        await #expect(throws: ToolFailure.self) {
            _ = try await tools.execute(action: "search", arguments: [:], defaultLimit: 20)
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
