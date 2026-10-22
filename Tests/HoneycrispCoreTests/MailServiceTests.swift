import Foundation
import Testing
import HoneycrispCore

/// An index reader that hands back one fixed thread, with whatever missing
/// bodies a test wants, and counts the calls.
private actor FakeEnvelopeIndex: EnvelopeIndexReading {
    var threadResult: MailThread
    private(set) var threadCalls = 0

    init(threadResult: MailThread) {
        self.threadResult = threadResult
    }

    func search(
        query: String?, mailbox: String?, from: String?, to: String?,
        since: Date?, until: Date?, unreadOnly: Bool, limit: Int
    ) async throws -> [MailMessageSummary] { [] }

    func mailboxes() async throws -> [String] { [] }

    func thread(id: String, limit: Int) async throws -> MailThread {
        threadCalls += 1
        return threadResult
    }

    func messageSummary(id: String) async throws -> MailMessageSummary? { nil }
}

/// A fetcher that answers from a table, or fails the way it is told to.
private actor FakeBodyFetcher: MailBodyFetching {
    var table: [String: Data] = [:]
    var failure: (any Error)?
    private(set) var requests: [[MissingBody]] = []

    func setSources(_ table: [String: Data]) { self.table = table }
    func setFailure(_ failure: any Error) { self.failure = failure }

    func sources(for missing: [MissingBody]) async throws -> [String: Data] {
        requests.append(missing)
        if let failure { throw failure }
        return table.filter { id, _ in missing.contains { $0.messageID == id } }
    }
}

private struct UnusedComposer: MailComposing {
    func compose(_ draft: MailDraft, send: Bool) async throws -> MailComposeReceipt {
        MailComposeReceipt(to: draft.to, cc: draft.cc, subject: draft.subject, sent: send)
    }
}

private struct UnusedStateWriter: MailStateWriting {
    func setState(messageIDs: [String], read: Bool?, flagged: Bool?) async throws -> Int { 0 }
    func delete(messageIDs: [String]) async throws -> Int { 0 }
}

private let archived = MissingBody(
    messageID: "102", mailboxURL: "imap://christian@p68-imap.mail.me.com/Archive")

private func thread(missing: [MissingBody]) -> MailThread {
    MailThread(
        id: "9001", subject: "Re: Q3 planning",
        participants: ["alex@studio.com", "me@me.com"],
        messages: [
            MailMessage(
                id: "101", from: "alex@studio.com", fromName: "Alex Rivera",
                to: ["me@me.com"], date: Date(timeIntervalSince1970: 1_750_000_000),
                body: "Planning looks good.", link: "message://%3Calex-101@studio.com%3E"),
            MailMessage(
                id: "102", from: "me@me.com", fromName: "Christian",
                to: ["alex@studio.com"], date: Date(timeIntervalSince1970: 1_750_000_600),
                body: "(body unavailable)", link: "message://%3Cme-102@me.com%3E"),
        ],
        missingBodies: missing)
}

private let archivedSource = Data(
    """
    From: me@me.com\r
    To: alex@studio.com\r
    Subject: Re: Q3 planning\r
    Content-Type: multipart/alternative; boundary="B"\r
    \r
    --B\r
    Content-Type: text/plain; charset=utf-8\r
    \r
    See you Thursday.\r
    --B\r
    Content-Type: text/html\r
    \r
    <p>ignored</p>\r
    --B--\r
    """.utf8)

private func service(index: FakeEnvelopeIndex, fetcher: FakeBodyFetcher) -> MailService {
    MailService(
        reader: index, composer: UnusedComposer(), marker: UnusedStateWriter(), fetcher: fetcher)
}

@Suite("Mail service")
struct MailServiceTests {
    @Test("a body that is not on disk is fetched from Mail and parsed")
    func fetchesMissingBody() async throws {
        let index = FakeEnvelopeIndex(threadResult: thread(missing: [archived]))
        let fetcher = FakeBodyFetcher()
        await fetcher.setSources(["102": archivedSource])
        let result = try await service(index: index, fetcher: fetcher).thread(id: "9001", limit: 10)

        #expect(await fetcher.requests == [[archived]])
        #expect(result.messages.map(\.body) == ["Planning looks good.", "See you Thursday."])
        #expect(result.messages.last?.link == "message://%3Cme-102@me.com%3E")
        #expect(result.downloadedBodies == 1)
        #expect(result.missingBodies.isEmpty)
    }

    @Test("a thread with every body on disk never asks Mail")
    func noMissingBodies() async throws {
        let index = FakeEnvelopeIndex(threadResult: thread(missing: []))
        let fetcher = FakeBodyFetcher()
        let result = try await service(index: index, fetcher: fetcher).thread(id: "9001", limit: 10)
        #expect(await fetcher.requests.isEmpty)
        #expect(result.downloadedBodies == 0)
    }

    @Test("resolving a thread for marking or flagging never asks Mail")
    func indexedThreadSkipsFetch() async throws {
        let index = FakeEnvelopeIndex(threadResult: thread(missing: [archived]))
        let fetcher = FakeBodyFetcher()
        let result = try await service(index: index, fetcher: fetcher)
            .indexedThread(id: "9001", limit: 10)
        #expect(await fetcher.requests.isEmpty)
        #expect(await index.threadCalls == 1)
        #expect(result.messages.map(\.id) == ["101", "102"])
    }

    @Test("a body Mail does not hand over keeps the placeholder")
    func unfetchedKeepsPlaceholder() async throws {
        let index = FakeEnvelopeIndex(threadResult: thread(missing: [archived]))
        let fetcher = FakeBodyFetcher()
        let result = try await service(index: index, fetcher: fetcher).thread(id: "9001", limit: 10)
        #expect(result.messages.last?.body == "(body unavailable)")
        #expect(result.downloadedBodies == 0)
        #expect(result.missingBodies == [archived])
    }

    @Test("any other fetch error keeps the placeholder instead of failing the thread")
    func fetchErrorKeepsPlaceholder() async throws {
        let index = FakeEnvelopeIndex(threadResult: thread(missing: [archived]))
        let fetcher = FakeBodyFetcher()
        await fetcher.setFailure(CocoaError(.fileReadUnknown))
        let result = try await service(index: index, fetcher: fetcher).thread(id: "9001", limit: 10)
        #expect(result.messages.first?.body == "Planning looks good.")
        #expect(result.messages.last?.body == "(body unavailable)")
    }

    @Test("an Automation block says how to fix it in the missing bodies")
    func automationBlocked() async throws {
        let index = FakeEnvelopeIndex(threadResult: thread(missing: [archived]))
        let fetcher = FakeBodyFetcher()
        await fetcher.setFailure(
            ToolFailure(
                "macOS is blocking Honeycrisp from driving Mail. Grant Automation access in System Settings under Privacy & Security, Automation, then try again."
            ))
        let result = try await service(index: index, fetcher: fetcher).thread(id: "9001", limit: 10)
        let body = try #require(result.messages.last?.body)
        #expect(body.hasPrefix("(body unavailable)"))
        #expect(body.contains("System Settings"))
        #expect(result.messages.first?.body == "Planning looks good.")
    }
}
