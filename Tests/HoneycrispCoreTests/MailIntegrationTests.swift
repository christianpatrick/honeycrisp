import Foundation
import Testing

@testable import HoneycrispCore

/// Real Envelope Index reads, opt in because they need Full Disk Access on
/// the test host (Terminal): HONEYCRISP_INTEGRATION=1 swift test
@Suite(
    "Mail integration",
    .enabled(if: ProcessInfo.processInfo.environment["HONEYCRISP_INTEGRATION"] == "1"))
struct MailIntegrationTests {
    @Test("search returns plausible rows from the real index")
    func search() async throws {
        let database = MailDatabase()
        let hits = try await database.search(query: "the", mailbox: nil, from: nil, to: nil, since: nil, until: nil, unreadOnly: false, limit: 5)
        for hit in hits {
            #expect(!hit.id.isEmpty)
            #expect(hit.date.timeIntervalSince1970 > 0)
        }
    }

    @Test("a found thread fetches with bodies attempted")
    func thread() async throws {
        let database = MailDatabase()
        guard let first = try await database.search(query: "a", mailbox: nil, from: nil, to: nil, since: nil, until: nil, unreadOnly: false, limit: 1).first
        else { return }
        let thread = try await database.thread(id: first.threadId, limit: 5)
        #expect(!thread.messages.isEmpty)
    }

    @Test("flag state toggles and restores on the newest inbox message")
    func flagRoundTrip() async throws {
        let database = MailDatabase()
        let inbox = try await database.search(
            query: nil, mailbox: "INBOX", from: nil, to: nil,
            since: nil, until: nil, unreadOnly: false, limit: 1)
        let message = try #require(inbox.first)
        let writer = AppleEventMailStateWriter()

        // Toggle away from the message's real state and back, so the
        // mailbox ends exactly where it started.
        let original = try await writer.flaggedStatus(messageID: message.id)
        let toggledCount = try await writer.setState(
            messageIDs: [message.id], read: nil, flagged: !original)
        #expect(toggledCount == 1)
        #expect(try await writer.flaggedStatus(messageID: message.id) == !original)

        _ = try await writer.setState(messageIDs: [message.id], read: nil, flagged: original)
        #expect(try await writer.flaggedStatus(messageID: message.id) == original)
    }
}
