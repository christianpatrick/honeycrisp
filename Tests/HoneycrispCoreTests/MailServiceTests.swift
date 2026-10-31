import Foundation
import Testing
import HoneycrispCore

/// An index reader that hands back one fixed thread, with whatever missing
/// bodies a test wants, and counts the calls. locations stands in for the
/// mailboxes table: message id to mailbox url.
private actor FakeEnvelopeIndex: EnvelopeIndexReading {
    var threadResult: MailThread
    var locations: [String: String]
    private(set) var threadCalls = 0

    init(threadResult: MailThread, locations: [String: String] = [:]) {
        self.threadResult = threadResult
        self.locations = locations
    }

    func mailboxURLs(forMessageIDs ids: [String]) async throws -> [String: String] {
        locations.filter { id, _ in ids.contains(id) }
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

/// A state writer that records what it was asked to change and confirms
/// only the ids it is told to, so tests can play out Mail answering for
/// some messages and not others. confirmed nil confirms everything.
/// stopsAfter plays out Mail going quiet partway through: the writer
/// confirms that many targets, then stops with a timeout. trashNames is
/// what Mail reports as its Trash mailboxes.
private actor RecordingStateWriter: MailStateWriting {
    struct StateCall: Equatable {
        let targets: [MailTarget]
        let read: Bool?
        let flagged: Bool?
    }

    var confirmed: Set<String>?
    var stopsAfter: Int?
    var trashNames: [String]
    private(set) var stateCalls: [StateCall] = []
    private(set) var deleteCalls: [[MailTarget]] = []

    init(
        confirmed: Set<String>? = nil, stopsAfter: Int? = nil,
        trashNames: [String] = ["Deleted Messages"]
    ) {
        self.confirmed = confirmed
        self.stopsAfter = stopsAfter
        self.trashNames = trashNames
    }

    func setState(_ targets: [MailTarget], read: Bool?, flagged: Bool?) async throws -> [String] {
        stateCalls.append(StateCall(targets: targets, read: read, flagged: flagged))
        return try answer(targets)
    }

    func delete(_ targets: [MailTarget]) async throws -> [String] {
        deleteCalls.append(targets)
        return try answer(targets)
    }

    func trashMailboxNames() async throws -> [String] { trashNames }

    private func answer(_ targets: [MailTarget]) throws -> [String] {
        let ids = targets.map(\.messageID).filter { confirmed?.contains($0) ?? true }
        if let stopsAfter, stopsAfter < targets.count {
            throw MailWriteStopped(
                confirmed: Array(ids.prefix(stopsAfter)),
                reason: "Mail took too long to answer. It may be busy syncing; try again in a moment.")
        }
        return ids
    }
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

private func service(
    index: FakeEnvelopeIndex, fetcher: FakeBodyFetcher = FakeBodyFetcher(),
    writer: RecordingStateWriter = RecordingStateWriter()
) -> MailService {
    MailService(reader: index, composer: UnusedComposer(), marker: writer, fetcher: fetcher)
}

private let inboxURL = "imap://8F2D61A4-1111-2222-3333-444444444444/INBOX"
private let junkURL = "imap://8F2D61A4-1111-2222-3333-444444444444/Junk"
private let trashURL = "imap://christian@p68-imap.mail.me.com/Deleted%20Messages"

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

/// GH-18: writes go to each message's own mailbox, and only what Mail
/// confirms is reported as done.
@Suite("Mail writes")
struct MailWriteTests {
    @Test("marking read hands the writer each message with its mailbox")
    func markReadTargets() async throws {
        let index = FakeEnvelopeIndex(
            threadResult: thread(missing: []), locations: ["35450": junkURL, "101": inboxURL])
        let writer = RecordingStateWriter()
        let marked = try await service(index: index, writer: writer)
            .markRead(messageIDs: ["35450", "101"])

        #expect(marked == 2)
        #expect(
            await writer.stateCalls == [
                .init(
                    targets: [
                        MailTarget(messageID: "35450", mailboxURL: junkURL),
                        MailTarget(messageID: "101", mailboxURL: inboxURL),
                    ],
                    read: true, flagged: nil)
            ])
    }

    @Test("flagging goes through the same targets")
    func setStateTargets() async throws {
        let index = FakeEnvelopeIndex(
            threadResult: thread(missing: []), locations: ["101": inboxURL])
        let writer = RecordingStateWriter()
        let changed = try await service(index: index, writer: writer)
            .setState(messageIDs: ["101"], read: nil, flagged: true)

        #expect(changed == 1)
        #expect(
            await writer.stateCalls == [
                .init(
                    targets: [MailTarget(messageID: "101", mailboxURL: inboxURL)],
                    read: nil, flagged: true)
            ])
    }

    @Test("an id the index does not know fails before Mail is asked")
    func unknownID() async throws {
        let index = FakeEnvelopeIndex(
            threadResult: thread(missing: []), locations: ["101": inboxURL])
        let writer = RecordingStateWriter()
        let error = await #expect(throws: ToolFailure.self) {
            _ = try await service(index: index, writer: writer)
                .markRead(messageIDs: ["101", "999"])
        }
        #expect(error?.message.contains("999") == true)
        #expect(await writer.stateCalls.isEmpty)
    }

    @Test("a message Mail does not confirm is never reported as marked")
    func unconfirmedSingle() async throws {
        // The Junk reproduction: Mail found nothing to change.
        let index = FakeEnvelopeIndex(
            threadResult: thread(missing: []), locations: ["35450": junkURL])
        let writer = RecordingStateWriter(confirmed: [])
        let error = await #expect(throws: ToolFailure.self) {
            _ = try await service(index: index, writer: writer).markRead(messageIDs: ["35450"])
        }
        #expect(error?.message.contains("35450") == true)
        #expect(error?.message.contains("search again") == true)
    }

    @Test("a thread Mail only partly confirms says how many changed and which did not")
    func unconfirmedPartial() async throws {
        let index = FakeEnvelopeIndex(
            threadResult: thread(missing: []),
            locations: ["101": inboxURL, "102": inboxURL, "103": junkURL])
        let writer = RecordingStateWriter(confirmed: ["101", "102"])
        let error = await #expect(throws: ToolFailure.self) {
            _ = try await service(index: index, writer: writer)
                .setState(messageIDs: ["101", "102", "103"], read: true, flagged: nil)
        }
        let message = try #require(error?.message)
        #expect(message.contains("2 of 3"))
        #expect(message.contains("103"))
        #expect(!message.contains("101"))
    }

    @Test("delete refuses mail already in the Trash and never asks Mail")
    func deleteRefusesTrash() async throws {
        let index = FakeEnvelopeIndex(
            threadResult: thread(missing: []), locations: ["101": inboxURL, "77": trashURL])
        let writer = RecordingStateWriter()
        let error = await #expect(throws: ToolFailure.self) {
            _ = try await service(index: index, writer: writer).delete(messageIDs: ["77"])
        }
        #expect(error?.message.contains("Trash") == true)
        #expect(await writer.deleteCalls.isEmpty)
    }

    @Test("deleting a thread skips the messages already in the Trash")
    func deleteSkipsTrash() async throws {
        let index = FakeEnvelopeIndex(
            threadResult: thread(missing: []), locations: ["101": inboxURL, "77": trashURL])
        let writer = RecordingStateWriter()
        let deleted = try await service(index: index, writer: writer)
            .delete(messageIDs: ["101", "77"])
        #expect(deleted == 1)
        #expect(
            await writer.deleteCalls == [[MailTarget(messageID: "101", mailboxURL: inboxURL)]])
    }

    @Test("delete moves mail from any other mailbox, once Mail confirms it")
    func deleteConfirmed() async throws {
        let index = FakeEnvelopeIndex(
            threadResult: thread(missing: []), locations: ["35450": junkURL])
        let writer = RecordingStateWriter()
        let deleted = try await service(index: index, writer: writer).delete(messageIDs: ["35450"])
        #expect(deleted == 1)
        #expect(
            await writer.deleteCalls == [[MailTarget(messageID: "35450", mailboxURL: junkURL)]])

        let refused = RecordingStateWriter(confirmed: [])
        await #expect(throws: ToolFailure.self) {
            _ = try await service(index: index, writer: refused).delete(messageIDs: ["35450"])
        }
    }
}

/// Review follow-ups to GH-18: what Mail itself calls the Trash, and a
/// writer that stops partway through a thread.
@Suite("Mail write edges")
struct MailWriteEdgeTests {
    @Test("delete skips a mailbox Mail reports as its Trash, whatever its name")
    func deleteSkipsMailTrash() async throws {
        let papierkorb = "imap://work%40example.com@imap.gmail.com/%5BGmail%5D/Papierkorb"
        let index = FakeEnvelopeIndex(
            threadResult: thread(missing: []), locations: ["101": inboxURL, "88": papierkorb])
        let writer = RecordingStateWriter(trashNames: ["Papierkorb"])
        let deleted = try await service(index: index, writer: writer)
            .delete(messageIDs: ["101", "88"])
        #expect(deleted == 1)
        #expect(
            await writer.deleteCalls == [[MailTarget(messageID: "101", mailboxURL: inboxURL)]])

        let error = await #expect(throws: ToolFailure.self) {
            _ = try await service(index: index, writer: writer).delete(messageIDs: ["88"])
        }
        #expect(error?.message.contains("Trash") == true)
    }

    @Test("the Trash name list holds even when Mail names its Trash differently")
    func deleteSkipsNamedTrash() async throws {
        let gmailTrash = "imap://work%40example.com@imap.gmail.com/%5BGmail%5D/Trash"
        let index = FakeEnvelopeIndex(
            threadResult: thread(missing: []),
            locations: ["101": inboxURL, "77": trashURL, "78": gmailTrash])
        let writer = RecordingStateWriter(trashNames: ["Papierkorb"])
        let deleted = try await service(index: index, writer: writer)
            .delete(messageIDs: ["101", "77", "78"])
        #expect(deleted == 1)
        #expect(
            await writer.deleteCalls == [[MailTarget(messageID: "101", mailboxURL: inboxURL)]])

        await #expect(throws: ToolFailure.self) {
            _ = try await service(index: index, writer: writer).delete(messageIDs: ["77"])
        }
    }

    @Test("when Mail cannot say where the Trash is, nothing is deleted")
    func deleteFailsClosedWithoutTrashNames() async throws {
        let index = FakeEnvelopeIndex(
            threadResult: thread(missing: []), locations: ["101": inboxURL])
        let writer = RecordingStateWriter(trashNames: [])
        await #expect(throws: ToolFailure.self) {
            _ = try await service(index: index, writer: writer).delete(messageIDs: ["101"])
        }
        #expect(await writer.deleteCalls.isEmpty)
    }

    @Test("Mail going quiet partway through a thread still says what changed")
    func stoppedPartway() async throws {
        let index = FakeEnvelopeIndex(
            threadResult: thread(missing: []),
            locations: ["101": inboxURL, "102": inboxURL, "103": junkURL])
        let writer = RecordingStateWriter(stopsAfter: 1)
        let error = await #expect(throws: ToolFailure.self) {
            _ = try await service(index: index, writer: writer)
                .markRead(messageIDs: ["101", "102", "103"])
        }
        let message = try #require(error?.message)
        #expect(message.contains("1 of 3"))
        #expect(message.contains("took too long"))
    }

    @Test("Mail going quiet on a single message passes its reason through")
    func stoppedSingle() async throws {
        let index = FakeEnvelopeIndex(
            threadResult: thread(missing: []), locations: ["101": inboxURL])
        let writer = RecordingStateWriter(stopsAfter: 0)
        let error = await #expect(throws: ToolFailure.self) {
            _ = try await service(index: index, writer: writer).markRead(messageIDs: ["101"])
        }
        #expect(
            error?.message
                == "Mail took too long to answer. It may be busy syncing; try again in a moment.")
    }

    @Test("an unconfirmed change does not claim the message is untouched")
    func unconfirmedWording() async throws {
        let index = FakeEnvelopeIndex(
            threadResult: thread(missing: []), locations: ["101": inboxURL])
        let writer = RecordingStateWriter(confirmed: [])
        let error = await #expect(throws: ToolFailure.self) {
            _ = try await service(index: index, writer: writer)
                .setState(messageIDs: ["101"], read: true, flagged: true)
        }
        #expect(error?.message.contains("unchanged") == false)
    }
}
