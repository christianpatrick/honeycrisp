import Foundation
import MCP
import Testing
import HoneycrispCore

private actor RecordingPresenter: ApprovalPresenting {
    let stream: AsyncStream<PendingApproval>
    private let continuation: AsyncStream<PendingApproval>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream(of: PendingApproval.self)
    }

    func present(_ approval: PendingApproval) async {
        continuation.yield(approval)
    }
}

@MainActor
@Suite("App model", .serialized)
struct AppModelTests {
    private func makeModel(
        executor: CapturingExecutor = CapturingExecutor(),
        presenter: RecordingPresenter = RecordingPresenter()
    ) -> AppModel {
        AppModel(
            configURL: tempStoreURL("config.json"),
            auditURL: tempStoreURL("audit.jsonl"),
            executor: executor,
            presenter: presenter,
            portOverride: 0,
            approvalTimeout: .seconds(10)
        )
    }

    private func post(_ body: Data, port: UInt16) async throws -> (Data, Int) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        request.httpMethod = "POST"
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private func initializeBody(client: String) -> Data {
        Data(
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"\#(Version.latest)","capabilities":{},"clientInfo":{"name":"\#(client)","version":"1.0"}}}"#
                .utf8)
    }

    private func callBody(tool: String, arguments: String = "{}") -> Data {
        Data(
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"\#(tool)","arguments":\#(arguments)}}"#
                .utf8)
    }

    @Test("the server starts on a real port, pauses, and the status line matches the design")
    func serverLifecycle() async throws {
        let model = makeModel()
        await model.start()
        guard case .running(let port) = model.serverState else {
            Issue.record("expected running, got \(model.serverState)")
            return
        }
        #expect(port > 0)
        let health = URL(string: "http://127.0.0.1:\(port)/health")!
        let (_, response) = try await URLSession.shared.data(from: health)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)

        model.pause()
        #expect(model.serverState == .paused)
        #expect(model.statusLine == "Server paused")
        await #expect(throws: (any Error).self) {
            _ = try await URLSession.shared.data(from: health)
        }
    }

    @Test("permission mutations persist to disk and apply to the live server")
    func livePermissions() async throws {
        let model = makeModel()
        await model.start()
        guard case .running(let port) = model.serverState else {
            Issue.record("server did not start")
            return
        }
        #expect(model.config.isOn(app: .messages, action: "send") == false)
        model.setAction("send", on: true, for: .messages)
        #expect(HoneycrispConfig.load(from: model.configURL).isOn(app: .messages, action: "send"))

        let list = Data(#"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#.utf8)
        let (data, _) = try await post(list, port: port)
        #expect(String(decoding: data, as: UTF8.self).contains("messages_send"))
        model.pause()
    }

    @Test("an approval round trip over the live server runs after Allow once")
    func approvalAllowed() async throws {
        let executor = CapturingExecutor()
        let presenter = RecordingPresenter()
        let model = makeModel(executor: executor, presenter: presenter)
        model.setAction("send", on: true, for: .messages)
        await model.start()
        guard case .running(let port) = model.serverState else {
            Issue.record("server did not start")
            return
        }

        let call = callBody(
            tool: "messages_send",
            arguments: #"{"recipient":"Maya","body":"on my way"}"#)
        async let response = post(call, port: port)

        var prompt: PendingApproval?
        for await presented in presenter.stream {
            prompt = presented
            break
        }
        #expect(prompt?.prompt.message.contains("Maya") == true)
        #expect(model.pendingApprovals.count == 1)

        await model.resolveApproval(id: prompt!.id, approved: true)
        let (data, status) = try await response
        #expect(status == 200)
        #expect(String(decoding: data, as: UTF8.self).contains(#"\"ok\":true"#) || String(decoding: data, as: UTF8.self).contains(#"ok"#))
        #expect(model.pendingApprovals.isEmpty)
        #expect(await executor.calls.count == 1)
        #expect(await model.audit.entries().first?.outcome == .asked)
        model.pause()
    }

    @Test("declining an approval blocks the call and audits denied")
    func approvalDeclined() async throws {
        let executor = CapturingExecutor()
        let presenter = RecordingPresenter()
        let model = makeModel(executor: executor, presenter: presenter)
        model.setAction("send", on: true, for: .messages)
        await model.start()
        guard case .running(let port) = model.serverState else {
            Issue.record("server did not start")
            return
        }

        let call = callBody(
            tool: "messages_send",
            arguments: #"{"recipient":"Maya","body":"on my way"}"#)
        async let response = post(call, port: port)
        var prompt: PendingApproval?
        for await presented in presenter.stream {
            prompt = presented
            break
        }
        await model.resolveApproval(id: prompt!.id, approved: false)
        let (data, _) = try await response
        #expect(String(decoding: data, as: UTF8.self).contains("did not allow"))
        #expect(await executor.calls.isEmpty)
        #expect(await model.audit.entries().first?.outcome == .denied)
        model.pause()
    }

    @Test("completing onboarding persists across model instances")
    func onboardingFlag() {
        let configURL = tempStoreURL("config.json")
        let model = AppModel(
            configURL: configURL,
            auditURL: tempStoreURL("audit.jsonl"),
            executor: CapturingExecutor(),
            presenter: RecordingPresenter(),
            portOverride: 0
        )
        #expect(model.config.onboardingCompleted == false)
        model.completeOnboarding()
        #expect(HoneycrispConfig.load(from: configURL).onboardingCompleted)
    }

    @Test("refresh pulls counts, entries, and connected clients")
    func refresh() async throws {
        let model = makeModel()
        await model.start()
        guard case .running(let port) = model.serverState else {
            Issue.record("server did not start")
            return
        }
        _ = try await post(initializeBody(client: "TestClient"), port: port)
        _ = try await post(
            callBody(tool: "mail_search", arguments: #"{"query":"x"}"#), port: port)
        await model.refresh()
        #expect(model.counts.requestsToday >= 1)
        #expect(model.entries.isEmpty == false)
        #expect(model.clients.map(\.name) == ["TestClient"])
        #expect(model.statusLine == "1 client connected")
        model.pause()
    }
}
