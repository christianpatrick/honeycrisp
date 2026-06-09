import Foundation
import MCP
import Testing
import HoneycrispCore

private let alexSummary = MailMessageSummary(
    id: "101",
    threadId: "9001",
    subject: "Re: Q3 planning",
    from: "alex@studio.com",
    fromName: "Alex Rivera",
    date: Date(timeIntervalSince1970: 1_750_000_000),
    mailbox: "INBOX",
    read: true
)

private actor FakeMailService: MailServicing {
    private(set) var searches: [(query: String, mailbox: String?, limit: Int)] = []
    private(set) var threadCalls: [(id: String, limit: Int)] = []
    private(set) var summaryCalls: [String] = []
    private(set) var drafts: [MailDraft] = []
    private(set) var sends: [MailDraft] = []

    var searchResult: [MailMessageSummary] = []
    var threadResult = MailThread(
        id: "9001", subject: "Re: Q3 planning",
        participants: ["alex@studio.com", "me@me.com"],
        messages: [
            MailMessage(
                id: "101", from: "alex@studio.com", fromName: "Alex Rivera",
                to: ["me@me.com"], date: Date(timeIntervalSince1970: 1_750_000_000),
                body: "Planning looks good."),
            MailMessage(
                id: "102", from: "me@me.com", fromName: "Christian",
                to: ["alex@studio.com"], date: Date(timeIntervalSince1970: 1_750_000_600),
                body: "See you Thursday."),
        ])
    var summaryResult: MailMessageSummary?

    func setSearchResult(_ result: [MailMessageSummary]) { searchResult = result }
    func setSummaryResult(_ result: MailMessageSummary?) { summaryResult = result }

    func search(query: String, mailbox: String?, limit: Int) async throws -> [MailMessageSummary] {
        searches.append((query, mailbox, limit))
        return searchResult
    }

    func thread(id: String, limit: Int) async throws -> MailThread {
        threadCalls.append((id, limit))
        return threadResult
    }

    func messageSummary(id: String) async throws -> MailMessageSummary? {
        summaryCalls.append(id)
        return summaryResult
    }

    func draft(_ draft: MailDraft) async throws -> MailComposeReceipt {
        drafts.append(draft)
        return MailComposeReceipt(to: draft.to, cc: draft.cc, subject: draft.subject, sent: false)
    }

    func send(_ draft: MailDraft) async throws -> MailComposeReceipt {
        sends.append(draft)
        return MailComposeReceipt(to: draft.to, cc: draft.cc, subject: draft.subject, sent: true)
    }
}

@Suite("Mail tools")
struct MailToolsTests {
    @Test("search passes arguments and round-trips JSON")
    func search() async throws {
        let service = FakeMailService()
        await service.setSearchResult([alexSummary])
        let tools = MailTools(service: service)
        let outcome = try await tools.execute(
            action: "search",
            arguments: ["query": "Q3", "mailbox": "INBOX", "limit": 5],
            defaultLimit: 20)
        let calls = await service.searches
        #expect(calls.first?.query == "Q3")
        #expect(calls.first?.mailbox == "INBOX")
        #expect(calls.first?.limit == 5)
        let decoded = try ToolJSON.decode([MailMessageSummary].self, from: outcome.content)
        #expect(decoded == [alexSummary])
        #expect(outcome.auditAction.contains("Q3"))

        await #expect(throws: ToolFailure.self) {
            _ = try await tools.execute(action: "search", arguments: [:], defaultLimit: 20)
        }
    }

    @Test("read returns the thread with the mock's audit copy")
    func readThread() async throws {
        let service = FakeMailService()
        let tools = MailTools(service: service)
        let outcome = try await tools.execute(
            action: "read", arguments: ["thread_id": "9001"], defaultLimit: 20)
        #expect(await service.threadCalls.first?.id == "9001")
        #expect(outcome.auditAction.contains("Re: Q3 planning"))
        #expect(outcome.auditSummary.contains("Returned the subject and 2 message bodies"))
        let decoded = try ToolJSON.decode(MailThread.self, from: outcome.content)
        #expect(decoded.messages.count == 2)

        await #expect(throws: ToolFailure.self) {
            _ = try await tools.execute(action: "read", arguments: [:], defaultLimit: 20)
        }
    }

    @Test("a reply draft with no recipients resolves the sender and a Re: subject")
    func replyResolution() async throws {
        let service = FakeMailService()
        await service.setSummaryResult(alexSummary)
        let tools = MailTools(service: service)
        let outcome = try await tools.execute(
            action: "draft",
            arguments: ["reply_to_message_id": "101", "body": "Sounds good."],
            defaultLimit: 20)
        #expect(await service.summaryCalls == ["101"])
        let drafts = await service.drafts
        #expect(drafts.first?.to == ["alex@studio.com"])
        #expect(drafts.first?.subject == "Re: Q3 planning")
        #expect(outcome.auditAction.contains("Alex Rivera"))
        #expect(outcome.auditSummary.contains("Nothing was sent"))
    }

    @Test("a reply never doubles the Re: prefix")
    func replyPrefix() async throws {
        let service = FakeMailService()
        await service.setSummaryResult(alexSummary)
        let tools = MailTools(service: service)
        _ = try await tools.execute(
            action: "draft",
            arguments: ["reply_to_message_id": "101", "body": "Sounds good."],
            defaultLimit: 20)
        #expect(await service.drafts.first?.subject == "Re: Q3 planning")
    }

    @Test("explicit recipients and subject win over reply resolution")
    func explicitFields() async throws {
        let service = FakeMailService()
        await service.setSummaryResult(alexSummary)
        let tools = MailTools(service: service)
        _ = try await tools.execute(
            action: "draft",
            arguments: [
                "reply_to_message_id": "101",
                "to": .array([.string("maya@studio.com")]),
                "subject": "Fresh subject",
                "body": "Hello.",
            ],
            defaultLimit: 20)
        let drafts = await service.drafts
        #expect(drafts.first?.to == ["maya@studio.com"])
        #expect(drafts.first?.subject == "Fresh subject")
    }

    @Test("send reports the approval-flavored audit copy")
    func send() async throws {
        let service = FakeMailService()
        let tools = MailTools(service: service)
        let outcome = try await tools.execute(
            action: "send",
            arguments: [
                "to": .array([.string("alex@studio.com")]),
                "subject": "Updates",
                "body": "All set.",
            ],
            defaultLimit: 20)
        #expect(await service.sends.count == 1)
        #expect(outcome.auditAction == "Sent a mail to alex@studio.com")
        #expect(outcome.auditSummary.contains("approved"))
    }

    @Test("compose without a body or without any recipient fails")
    func composeValidation() async {
        let service = FakeMailService()
        let tools = MailTools(service: service)
        await #expect(throws: ToolFailure.self) {
            _ = try await tools.execute(
                action: "send",
                arguments: ["to": .array([.string("a@b.com")])],
                defaultLimit: 20)
        }
        await #expect(throws: ToolFailure.self) {
            _ = try await tools.execute(
                action: "draft", arguments: ["body": "hi"], defaultLimit: 20)
        }
    }

    @Test("an unknown mail action fails")
    func unknownAction() async {
        let tools = MailTools(service: FakeMailService())
        await #expect(throws: ToolFailure.self) {
            _ = try await tools.execute(action: "archive", arguments: [:], defaultLimit: 20)
        }
    }

    @Test("the executor routes mail when wired")
    func executorRouting() async throws {
        let service = FakeMailService()
        await service.setSearchResult([alexSummary])
        let executor = ServiceExecutor(configProvider: { .default }, mail: service)
        let outcome = try await executor.execute(
            app: .mail, action: "search", arguments: ["query": "Q3"])
        #expect(outcome.content.contains("Q3 planning"))
    }
}
