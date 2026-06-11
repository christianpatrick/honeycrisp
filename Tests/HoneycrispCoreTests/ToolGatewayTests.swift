import Foundation
import MCP
import Testing
import HoneycrispCore

/// Records every execute call and returns a scripted outcome or error.
private actor RecordingExecutor: ToolExecutor {
    struct Call: Sendable {
        let app: AppID
        let action: String
        let arguments: [String: Value]
    }

    private(set) var calls: [Call] = []
    var outcome = ToolOutcome(
        content: #"{"ok":true}"#,
        auditAction: "Did the thing",
        auditSummary: "Returned a thing. Nothing was modified.",
        auditRows: [AuditDetailRow(label: "Thing", value: "1")]
    )
    var failure: ToolFailure?

    func setFailure(_ failure: ToolFailure) {
        self.failure = failure
    }

    func execute(app: AppID, action: String, arguments: [String: Value]) async throws -> ToolOutcome {
        calls.append(Call(app: app, action: action, arguments: arguments))
        if let failure { throw failure }
        return outcome
    }
}

/// Answers every approval request the same way and records the prompts.
private actor ScriptedBroker: ApprovalRequesting {
    private let answer: Bool
    private(set) var prompts: [ApprovalPrompt] = []

    init(answer: Bool) {
        self.answer = answer
    }

    func requestApproval(_ prompt: ApprovalPrompt) async -> Bool {
        prompts.append(prompt)
        return answer
    }
}

@Suite("Tool gateway")
struct ToolGatewayTests {
    private func tempAuditURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("honeycrisp-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("audit.jsonl")
    }

    private func makeGateway(
        config: HoneycrispConfig = .default,
        executor: RecordingExecutor = RecordingExecutor(),
        audit: AuditStore,
        broker: ScriptedBroker? = nil
    ) -> ToolGateway {
        ToolGateway(
            configProvider: { config },
            executor: executor,
            audit: audit,
            approvals: broker,
            clientName: { "Claude Desktop" }
        )
    }

    @Test("the default config lists exactly the fourteen visible tools")
    func defaultListing() {
        let gateway = makeGateway(audit: AuditStore(fileURL: tempAuditURL()))
        let names = Set(gateway.listTools().map(\.name))
        #expect(
            names == [
                "mail_search", "mail_read", "mail_draft",
                "reminders_list", "reminders_due", "reminders_create", "reminders_complete",
                "calendar_today", "calendar_list",
                "messages_recent", "messages_search", "messages_history",
                "contacts_lookup", "contacts_fields",
            ])
    }

    @Test("enabling an action makes its tool appear")
    func listingFollowsConfig() {
        var config = HoneycrispConfig.default
        config.setAction("send", on: true, for: .messages)
        let gateway = makeGateway(config: config, audit: AuditStore(fileURL: tempAuditURL()))
        #expect(gateway.listTools().map(\.name).contains("messages_send"))
    }

    @Test("an unknown tool errors without touching the executor or the audit log")
    func unknownTool() async {
        let executor = RecordingExecutor()
        let audit = AuditStore(fileURL: tempAuditURL())
        let gateway = makeGateway(executor: executor, audit: audit)
        let result = await gateway.callTool(name: "mail_teleport", arguments: [:])
        #expect(result.isError)
        #expect(result.content.contains("no tool named"))
        #expect(await executor.calls.isEmpty)
        #expect(await audit.entries().isEmpty)
    }

    @Test("a switched-off action is blocked, audited, and never executed")
    func deniedActionOff() async {
        let executor = RecordingExecutor()
        let audit = AuditStore(fileURL: tempAuditURL())
        let gateway = makeGateway(executor: executor, audit: audit)
        let result = await gateway.callTool(name: "mail_send", arguments: ["body": "hi"])
        #expect(result.isError)
        #expect(result.content.contains("turned off"))
        #expect(await executor.calls.isEmpty)
        let entries = await audit.entries()
        #expect(entries.count == 1)
        #expect(entries.first?.outcome == .denied)
        #expect(entries.first?.app == .mail)
        #expect(entries.first?.actionID == "send")
        #expect(entries.first?.client == "Claude Desktop")
    }

    @Test("an allowed call reaches the executor and audits with a duration row")
    func allowedCall() async {
        let executor = RecordingExecutor()
        let audit = AuditStore(fileURL: tempAuditURL())
        let gateway = makeGateway(executor: executor, audit: audit)
        let result = await gateway.callTool(name: "mail_search", arguments: ["query": "planning"])
        #expect(result.isError == false)
        #expect(result.content == #"{"ok":true}"#)
        let calls = await executor.calls
        #expect(calls.count == 1)
        #expect(calls.first?.app == .mail)
        #expect(calls.first?.action == "search")
        #expect(calls.first?.arguments == ["query": "planning"])
        let entries = await audit.entries()
        #expect(entries.first?.outcome == .allowed)
        #expect(entries.first?.action == "Did the thing")
        #expect(entries.first?.rows.map(\.label).contains("Thing") == true)
        #expect(entries.first?.rows.map(\.label).contains("Duration") == true)
    }

    @Test("approval-required actions fail closed when no broker is wired")
    func approvalWithoutBroker() async {
        var config = HoneycrispConfig.default
        config.setAction("send", on: true, for: .messages)
        let executor = RecordingExecutor()
        let audit = AuditStore(fileURL: tempAuditURL())
        let gateway = makeGateway(config: config, executor: executor, audit: audit)
        let result = await gateway.callTool(
            name: "messages_send", arguments: ["recipient": "Maya", "body": "hi"])
        #expect(result.isError)
        #expect(result.content.contains("menu bar app"))
        #expect(await executor.calls.isEmpty)
        #expect(await audit.entries().first?.outcome == .denied)
    }

    @Test("an approved request runs and audits as asked, with the recipient in the prompt")
    func approvedRequest() async {
        var config = HoneycrispConfig.default
        config.setAction("send", on: true, for: .messages)
        let executor = RecordingExecutor()
        let audit = AuditStore(fileURL: tempAuditURL())
        let broker = ScriptedBroker(answer: true)
        let gateway = makeGateway(config: config, executor: executor, audit: audit, broker: broker)
        let result = await gateway.callTool(
            name: "messages_send", arguments: ["recipient": "alex@studio.com", "body": "hi"])
        #expect(result.isError == false)
        #expect(await executor.calls.count == 1)
        #expect(await audit.entries().first?.outcome == .asked)
        let prompts = await broker.prompts
        #expect(prompts.count == 1)
        #expect(prompts.first?.message.contains("alex@studio.com") == true)
        #expect(prompts.first?.client == "Claude Desktop")
    }

    @Test("a declined request never executes and nothing leaves the Mac")
    func declinedRequest() async {
        var config = HoneycrispConfig.default
        config.setAction("send", on: true, for: .messages)
        let executor = RecordingExecutor()
        let audit = AuditStore(fileURL: tempAuditURL())
        let broker = ScriptedBroker(answer: false)
        let gateway = makeGateway(config: config, executor: executor, audit: audit, broker: broker)
        let result = await gateway.callTool(
            name: "messages_send", arguments: ["recipient": "Maya", "body": "hi"])
        #expect(result.isError)
        #expect(result.content.contains("nothing left your Mac"))
        #expect(await executor.calls.isEmpty)
        #expect(await audit.entries().first?.outcome == .denied)
    }

    @Test("an executor failure reports the message and audits as allowed but failed")
    func executorFailure() async {
        let executor = RecordingExecutor()
        await executor.setFailure(ToolFailure("Mail's index is not reachable."))
        let audit = AuditStore(fileURL: tempAuditURL())
        let gateway = makeGateway(executor: executor, audit: audit)
        let result = await gateway.callTool(name: "mail_search", arguments: [:])
        #expect(result.isError)
        #expect(result.content.contains("Mail's index is not reachable."))
        let entries = await audit.entries()
        #expect(entries.first?.outcome == .allowed)
        #expect(entries.first?.summary.contains("failed") == true)
    }

    @Test("a read level blocks writes even when a switch was hand-edited on")
    func readOnlyLevel() async throws {
        let json = #"{"levels": {"messages": "read"}, "switches": {"messages": {"send": true}}}"#
        let config = try JSONDecoder().decode(HoneycrispConfig.self, from: Data(json.utf8))
        let executor = RecordingExecutor()
        let audit = AuditStore(fileURL: tempAuditURL())
        let gateway = makeGateway(config: config, executor: executor, audit: audit)
        let result = await gateway.callTool(
            name: "messages_send", arguments: ["recipient": "Maya", "body": "hi"])
        #expect(result.isError)
        #expect(result.content.contains("read only"))
        #expect(await executor.calls.isEmpty)
        #expect(await audit.entries().first?.outcome == .denied)
    }
}
