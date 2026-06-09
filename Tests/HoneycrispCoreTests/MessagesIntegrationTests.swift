import Foundation
import Testing
import HoneycrispCore

/// Real chat.db reads, opt in because they need Full Disk Access on the
/// test host (Terminal): HONEYCRISP_INTEGRATION=1 swift test
@Suite(
    "Messages integration",
    .enabled(if: ProcessInfo.processInfo.environment["HONEYCRISP_INTEGRATION"] == "1"))
struct MessagesIntegrationTests {
    @Test("recent returns plausible conversations from the real database")
    func recent() async throws {
        let database = ChatDatabase()
        let conversations = try await database.recentConversations(limit: 5)
        #expect(!conversations.isEmpty)
        for conversation in conversations {
            #expect(!conversation.id.isEmpty)
            #expect(!conversation.lastMessage.isEmpty)
            #expect(conversation.lastAt.timeIntervalSinceReferenceDate > 0)
        }
    }

    @Test("search runs against the real database without error")
    func search() async throws {
        let database = ChatDatabase()
        _ = try await database.searchMessages(query: "the", contact: nil, limit: 5)
    }
}
