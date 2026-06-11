import Foundation
import MCP
import Testing
import HoneycrispCore

private struct Envelope<P: Encodable>: Encodable {
    let jsonrpc = "2.0"
    var id: Int?
    let method: String
    var params: P?
}

private struct ResponseEnvelope<R: Decodable>: Decodable {
    struct ErrorObject: Decodable {
        let code: Int
        let message: String
    }
    let id: Value?
    let result: R?
    let error: ErrorObject?
}

private func encode<P: Encodable>(_ envelope: Envelope<P>) -> Data {
    try! JSONEncoder().encode(envelope)
}

private func initializeBody(id: Int = 1, client: String, version: String = Version.latest) -> Data {
    encode(
        Envelope(
            id: id, method: "initialize",
            params: Initialize.Parameters(
                protocolVersion: version,
                capabilities: .init(),
                clientInfo: .init(name: client, version: "1.0")
            )))
}

private func callBody(id: Int = 2, tool: String, arguments: [String: Value] = [:]) -> Data {
    encode(
        Envelope(id: id, method: "tools/call", params: CallTool.Parameters(name: tool, arguments: arguments)))
}

@Suite("MCP HTTP router")
struct MCPHTTPRouterTests {
    private func makeRouter(
        config: HoneycrispConfig = .default,
        executor: CapturingExecutor = CapturingExecutor(),
        audit: AuditStore
    ) -> (MCPHTTPRouter, ClientRegistry) {
        let clients = ClientRegistry()
        let gateway = ToolGateway(
            configProvider: { config },
            executor: executor,
            audit: audit,
            approvals: nil
        )
        return (MCPHTTPRouter(gateway: gateway, clients: clients), clients)
    }

    @Test("initialize negotiates, answers as Honeycrisp, and records the client")
    func initialize() async throws {
        let (router, clients) = makeRouter(audit: AuditStore(fileURL: tempStoreURL("audit.jsonl")))
        let response = await router.handle(body: initializeBody(client: "Claude Desktop"), clientHeader: nil)
        #expect(response.status == 200)
        let decoded = try JSONDecoder().decode(
            ResponseEnvelope<Initialize.Result>.self, from: response.body)
        #expect(decoded.result?.serverInfo.name == "Honeycrisp")
        #expect(Version.supported.contains(decoded.result?.protocolVersion ?? ""))
        #expect(await clients.list().map(\.name) == ["Claude Desktop"])
    }

    @Test("an unsupported protocol version negotiates down to the latest supported")
    func versionNegotiation() async throws {
        let (router, _) = makeRouter(audit: AuditStore(fileURL: tempStoreURL("audit.jsonl")))
        let response = await router.handle(
            body: initializeBody(client: "Old Client", version: "1999-01-01"), clientHeader: nil)
        let decoded = try JSONDecoder().decode(
            ResponseEnvelope<Initialize.Result>.self, from: response.body)
        #expect(decoded.result?.protocolVersion == Version.latest)
    }

    @Test("a second initialize succeeds because the hub serves many clients")
    func repeatedInitialize() async throws {
        let (router, clients) = makeRouter(audit: AuditStore(fileURL: tempStoreURL("audit.jsonl")))
        _ = await router.handle(body: initializeBody(client: "Claude Desktop"), clientHeader: nil)
        let second = await router.handle(body: initializeBody(client: "Zed"), clientHeader: nil)
        #expect(second.status == 200)
        let decoded = try JSONDecoder().decode(
            ResponseEnvelope<Initialize.Result>.self, from: second.body)
        #expect(decoded.error == nil)
        #expect(decoded.result != nil)
        #expect(await clients.list().count == 2)
    }

    @Test("tools/list reflects the config gating")
    func toolsList() async throws {
        let (router, _) = makeRouter(audit: AuditStore(fileURL: tempStoreURL("audit.jsonl")))
        let response = await router.handle(
            body: encode(Envelope<Int>(id: 3, method: "tools/list", params: nil)),
            clientHeader: nil)
        let decoded = try JSONDecoder().decode(
            ResponseEnvelope<ListTools.Result>.self, from: response.body)
        #expect(decoded.result?.tools.count == 14)
    }

    @Test("the client header attributes the audit entry per request")
    func headerAttribution() async throws {
        let audit = AuditStore(fileURL: tempStoreURL("audit.jsonl"))
        let (router, _) = makeRouter(audit: audit)
        _ = await router.handle(body: initializeBody(client: "Claude Desktop"), clientHeader: nil)
        _ = await router.handle(
            body: callBody(tool: "mail_search", arguments: ["query": "x"]), clientHeader: "Zed")
        #expect(await audit.entries().first?.client == "Zed")
    }

    @Test("without a header the last initialized client is the best effort")
    func fallbackAttribution() async throws {
        let audit = AuditStore(fileURL: tempStoreURL("audit.jsonl"))
        let (router, _) = makeRouter(audit: audit)
        _ = await router.handle(body: initializeBody(client: "Claude Desktop"), clientHeader: nil)
        _ = await router.handle(
            body: callBody(tool: "mail_search", arguments: ["query": "x"]), clientHeader: nil)
        #expect(await audit.entries().first?.client == "Claude Desktop")
    }

    @Test("notifications return 202 with an empty body")
    func notifications() async {
        let (router, _) = makeRouter(audit: AuditStore(fileURL: tempStoreURL("audit.jsonl")))
        let body = Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)
        let response = await router.handle(body: body, clientHeader: nil)
        #expect(response.status == 202)
        #expect(response.body.isEmpty)
    }

    @Test("ping answers an empty result")
    func ping() async throws {
        let (router, _) = makeRouter(audit: AuditStore(fileURL: tempStoreURL("audit.jsonl")))
        let response = await router.handle(
            body: encode(Envelope<Int>(id: 9, method: "ping", params: nil)), clientHeader: nil)
        let decoded = try JSONDecoder().decode(ResponseEnvelope<Value>.self, from: response.body)
        #expect(decoded.result != nil)
        #expect(decoded.error == nil)
    }

    @Test("unknown methods and garbage bodies map to JSON-RPC errors")
    func errors() async throws {
        let (router, _) = makeRouter(audit: AuditStore(fileURL: tempStoreURL("audit.jsonl")))
        let unknown = await router.handle(
            body: encode(Envelope<Int>(id: 5, method: "resources/list", params: nil)),
            clientHeader: nil)
        let unknownDecoded = try JSONDecoder().decode(
            ResponseEnvelope<Value>.self, from: unknown.body)
        #expect(unknownDecoded.error?.code == -32601)
        #expect(unknownDecoded.id == .int(5))

        let garbage = await router.handle(body: Data("{nope".utf8), clientHeader: nil)
        let garbageDecoded = try JSONDecoder().decode(
            ResponseEnvelope<Value>.self, from: garbage.body)
        #expect(garbageDecoded.error?.code == -32700)
    }

    @Test("array results omit structuredContent so strict clients accept them")
    func arrayResultsOmitStructuredContent() async throws {
        let executor = CapturingExecutor()
        await executor.setOutcome(
            ToolOutcome(
                content: #"[{"title":"Call the dentist"}]"#,
                auditAction: "Checked what is due today",
                auditSummary: "Read 1 reminder. Nothing was modified."
            ))
        let (router, _) = makeRouter(
            executor: executor, audit: AuditStore(fileURL: tempStoreURL("audit.jsonl")))
        let response = await router.handle(
            body: callBody(tool: "reminders_due"), clientHeader: nil)
        let raw = try JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        let result = try #require(raw?["result"] as? [String: Any])
        #expect(result["structuredContent"] == nil)
        #expect(result["content"] != nil)
        let text = String(decoding: response.body, as: UTF8.self)
        #expect(text.contains("Call the dentist"))
    }

    @Test("object results keep structuredContent")
    func objectResultsKeepStructuredContent() async throws {
        let (router, _) = makeRouter(audit: AuditStore(fileURL: tempStoreURL("audit.jsonl")))
        let response = await router.handle(
            body: callBody(tool: "mail_search", arguments: ["query": "x"]), clientHeader: nil)
        let raw = try JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        let result = try #require(raw?["result"] as? [String: Any])
        #expect(result["structuredContent"] as? [String: Any] != nil)
    }

    @Test("a tool the gateway refuses comes back as an isError result, not a protocol error")
    func gatewayRefusal() async throws {
        let (router, _) = makeRouter(audit: AuditStore(fileURL: tempStoreURL("audit.jsonl")))
        let response = await router.handle(
            body: callBody(tool: "mail_send", arguments: ["body": "x"]), clientHeader: nil)
        let decoded = try JSONDecoder().decode(
            ResponseEnvelope<CallTool.Result>.self, from: response.body)
        #expect(decoded.result?.isError == true)
    }
}
