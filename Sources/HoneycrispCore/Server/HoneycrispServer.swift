import Foundation
import MCP

/// Thin adapter that mounts a ToolGateway on the MCP SDK server. The
/// gateway holds all the logic; this file only translates protocol shapes.
public enum HoneycrispServer {
    public static func make() -> Server {
        Server(
            name: "Honeycrisp",
            version: HoneycrispInfo.version,
            instructions:
                "Honeycrisp gives you fast, private, native access to this Mac's Mail, Reminders, Calendar, Messages, and Contacts. Reads return structured JSON. Sends go out only after the user approves a notification.",
            capabilities: .init(tools: .init(listChanged: false))
        )
    }

    /// tools/list and tools/call route through the gateway. Initialize and
    /// Ping stay with the SDK defaults installed by start(); see the
    /// AGENTS.md findings about handler clobbering before re-registering
    /// anything around Initialize.
    public static func registerHandlers(on server: Server, gateway: ToolGateway) async {
        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: gateway.listTools())
        }
        await server.withMethodHandler(CallTool.self) { params in
            let result = await gateway.callTool(
                name: params.name, arguments: params.arguments ?? [:])
            return CallTool.Result(
                content: [.text(result.content)],
                structuredContent: result.isError
                    ? nil : MCPHTTPRouter.objectValue(result.content),
                isError: result.isError
            )
        }
    }

    /// Serves one stdio client until it disconnects. One process serves one
    /// client, so the initialize hook's client name attributes the audit
    /// entries exactly.
    public static func runStdio(
        configProvider: @escaping @Sendable () -> HoneycrispConfig,
        executor: any ToolExecutor,
        audit: AuditStore?,
        approvals: (any ApprovalRequesting)? = nil
    ) async throws {
        let clientBox = ClientNameBox()
        let gateway = ToolGateway(
            configProvider: configProvider,
            executor: executor,
            audit: audit,
            approvals: approvals,
            clientName: { clientBox.name }
        )
        let server = make()
        await registerHandlers(on: server, gateway: gateway)
        try await server.start(transport: StdioTransport()) { clientInfo, _ in
            clientBox.name = clientInfo.name
        }
        await server.waitUntilCompleted()
    }
}

/// Lets the initialize hook hand the client name to audit entries recorded
/// later in the session.
final class ClientNameBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedName = "Unknown client"

    var name: String {
        get { lock.withLock { storedName } }
        set { lock.withLock { storedName = newValue } }
    }
}
