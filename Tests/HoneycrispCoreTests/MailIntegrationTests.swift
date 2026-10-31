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

    @Test("flag state toggles and restores on the newest inbox and archived messages")
    func flagRoundTrip() async throws {
        let database = MailDatabase()
        let writer = AppleEventMailStateWriter()
        for mailbox in ["INBOX", "Archive"] {
            let newest = try await database.search(
                query: nil, mailbox: mailbox, from: nil, to: nil,
                since: nil, until: nil, unreadOnly: false, limit: 1)
            guard let message = newest.first else { continue }
            let url = try #require(
                try await database.mailboxURLs(forMessageIDs: [message.id])[message.id])
            let target = MailTarget(messageID: message.id, mailboxURL: url)

            // Toggle away from the message's real state and back, so the
            // mailbox ends exactly where it started.
            let status = try await writer.flaggedStatus(of: target)
            let original = try #require(status as Bool?)
            let toggled = try await writer.setState([target], read: nil, flagged: !original)
            #expect(toggled == [message.id])
            #expect(try await writer.flaggedStatus(of: target) == !original)

            let restored = try await writer.setState([target], read: nil, flagged: original)
            #expect(restored == [message.id])
            #expect(try await writer.flaggedStatus(of: target) == original)
        }
    }

    @Test("a message Mail cannot find comes back unconfirmed, not changed")
    func missingMessageUnconfirmed() async throws {
        let database = MailDatabase()
        let newest = try await database.search(
            query: nil, mailbox: "INBOX", from: nil, to: nil,
            since: nil, until: nil, unreadOnly: false, limit: 1)
        let message = try #require(newest.first)
        let url = try #require(
            try await database.mailboxURLs(forMessageIDs: [message.id])[message.id])
        let ghost = MailTarget(messageID: "2147483000", mailboxURL: url)
        let writer = AppleEventMailStateWriter()
        #expect(try await writer.setState([ghost], read: true, flagged: nil).isEmpty)
        #expect(try await writer.delete([ghost]).isEmpty)
    }

    @Test("recent rows carry well formed links when the index keeps the header")
    func links() async throws {
        let database = MailDatabase()
        let hits = try await database.search(
            query: nil, mailbox: nil, from: nil, to: nil,
            since: nil, until: nil, unreadOnly: false, limit: 50)
        for link in hits.compactMap(\.link) {
            #expect(link.hasPrefix("message://%3C"))
            #expect(link.hasSuffix("%3E"))
        }
    }

    /// The GH-12 assumption: asking Mail for the source of a message it
    /// never downloaded makes Mail fetch it. Looks through older archived
    /// threads for a body that is not on disk; when every one already is,
    /// there is nothing to prove on this Mac and the test returns.
    @Test("Mail hands over a body that is not on disk, and the read state holds")
    func fetchMissingBody() async throws {
        let database = MailDatabase()
        let candidates = try await database.search(
            query: nil, mailbox: "Archive", from: nil, to: nil, since: nil,
            until: Date().addingTimeInterval(-365 * 86_400), unreadOnly: false, limit: 10)
        var target: (missing: MissingBody, read: Bool)?
        for summary in candidates {
            let thread = try await database.thread(id: summary.threadId, limit: 20)
            if let missing = thread.missingBodies.first,
                let before = try await database.messageSummary(id: missing.messageID)
            {
                target = (missing, before.read)
                break
            }
        }
        guard let target else { return }

        let sources = try await AppleEventMailBodyFetcher().sources(for: [target.missing])
        let source = try #require(sources[target.missing.messageID])
        #expect(MimeText.bodyText(fromRFC822: source)?.isEmpty == false)
        let after = try await database.messageSummary(id: target.missing.messageID)
        #expect(after?.read == target.read)
    }
}
