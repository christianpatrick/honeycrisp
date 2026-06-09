import Foundation
import MCP
import Network

/// One client that has initialized against the hub.
public struct ConnectedClient: Sendable, Equatable, Identifiable {
    public let name: String
    public let since: Date
    public var lastSeen: Date

    public var id: String { name }
}

/// Records who initialized and when, for the panel header and for
/// best-effort audit attribution when a request carries no client header.
public actor ClientRegistry {
    private var clients: [String: ConnectedClient] = [:]
    private var order: [String] = []
    private var last: String?

    public init() {}

    public func record(name: String) {
        let now = Date()
        if var existing = clients[name] {
            existing.lastSeen = now
            clients[name] = existing
        } else {
            clients[name] = ConnectedClient(name: name, since: now, lastSeen: now)
            order.append(name)
        }
        last = name
    }

    public func touch(name: String) {
        guard var existing = clients[name] else { return }
        existing.lastSeen = Date()
        clients[name] = existing
    }

    public func list() -> [ConnectedClient] {
        order.compactMap { clients[$0] }
    }

    public func lastName() -> String? {
        last
    }
}

/// What the router hands back for one HTTP body.
public struct RouterResponse: Sendable, Equatable {
    public let status: Int
    public let body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }
}

/// Routes MCP-over-HTTP JSON-RPC to the gateway. We own this routing (the
/// SDK transport is not in this path), which is what makes repeated
/// initialize trivially fine and per-request client attribution possible.
/// Wire shapes reuse the SDK's public Codable types so they stay
/// spec-correct.
public struct MCPHTTPRouter: Sendable {
    private let gateway: ToolGateway
    private let clients: ClientRegistry

    public init(gateway: ToolGateway, clients: ClientRegistry) {
        self.gateway = gateway
        self.clients = clients
    }

    private struct Envelope: Decodable {
        let id: Value?
        let method: String?
        let params: Value?
    }

    public func handle(body: Data, clientHeader: String?) async -> RouterResponse {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: body),
            let method = envelope.method
        else {
            return error(id: .null, code: -32700, message: "That was not parseable JSON-RPC.")
        }

        // Notifications have no id and never get a body back.
        if envelope.id == nil {
            return RouterResponse(status: 202, body: Data())
        }
        let id = envelope.id ?? .null

        switch method {
        case "initialize":
            guard let params: Initialize.Parameters = decode(envelope.params) else {
                return error(id: id, code: -32602, message: "initialize needs clientInfo.")
            }
            await clients.record(name: params.clientInfo.name)
            let negotiated =
                Version.supported.contains(params.protocolVersion)
                ? params.protocolVersion : Version.latest
            let result = Initialize.Result(
                protocolVersion: negotiated,
                capabilities: .init(tools: .init(listChanged: false)),
                serverInfo: .init(name: "Honeycrisp", version: HoneycrispInfo.version),
                instructions:
                    "Honeycrisp gives you fast, private, native access to this Mac's Mail, Reminders, Messages, and Contacts. Reads return structured JSON. Sends go out only after the user approves a notification."
            )
            return respond(id: id, result: result)

        case "ping":
            return respond(id: id, result: [String: String]())

        case "tools/list":
            return respond(id: id, result: ListTools.Result(tools: gateway.listTools()))

        case "tools/call":
            guard let params: CallTool.Parameters = decode(envelope.params) else {
                return error(id: id, code: -32602, message: "tools/call needs a tool name.")
            }
            let client: String?
            if let clientHeader, !clientHeader.isEmpty {
                client = clientHeader
                await clients.touch(name: clientHeader)
            } else {
                client = await clients.lastName()
            }
            let result = await gateway.callTool(
                name: params.name, arguments: params.arguments ?? [:], client: client)
            let payload = CallTool.Result(
                content: [.text(result.content)],
                structuredContent: result.isError ? nil : Self.objectValue(result.content),
                isError: result.isError
            )
            return respond(id: id, result: payload)

        default:
            return error(
                id: id, code: -32601, message: "Honeycrisp does not handle \(method).")
        }
    }

    // MARK: - Envelopes

    /// The MCP spec defines structuredContent as a JSON object, and strict
    /// clients (Claude Desktop) reject whole tool results that violate it,
    /// so arrays and scalars send no structuredContent at all. The content
    /// text carries the full JSON either way.
    static func objectValue(_ json: String) -> Value? {
        guard let value = try? JSONDecoder().decode(Value.self, from: Data(json.utf8)),
            case .object = value
        else { return nil }
        return value
    }

    private func decode<T: Decodable>(_ params: Value?) -> T? {
        guard let params, let data = try? JSONEncoder().encode(params) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private struct ResultEnvelope<R: Encodable>: Encodable {
        let jsonrpc = "2.0"
        let id: Value
        let result: R
    }

    private struct ErrorEnvelope: Encodable {
        struct ErrorObject: Encodable {
            let code: Int
            let message: String
        }
        let jsonrpc = "2.0"
        let id: Value
        let error: ErrorObject
    }

    private func respond<R: Encodable>(id: Value, result: R) -> RouterResponse {
        guard let data = try? JSONEncoder().encode(ResultEnvelope(id: id, result: result)) else {
            return error(id: id, code: -32603, message: "Honeycrisp could not encode the result.")
        }
        return RouterResponse(status: 200, body: data)
    }

    private func error(id: Value, code: Int, message: String) -> RouterResponse {
        let envelope = ErrorEnvelope(id: id, error: .init(code: code, message: message))
        let data = (try? JSONEncoder().encode(envelope)) ?? Data()
        return RouterResponse(status: 200, body: data)
    }
}

/// The loopback socket layer: NWListener on 127.0.0.1, minimal HTTP/1.1,
/// POST /mcp to the router, GET /health, optional bearer enforcement,
/// Connection: close per request.
public final class LoopbackHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "app.honeycrisp.http")
    public let port: UInt16

    private init(listener: NWListener, port: UInt16) {
        self.listener = listener
        self.port = port
    }

    public static func start(port: UInt16, bearerToken: String?, router: MCPHTTPRouter)
        async throws -> LoopbackHTTPServer
    {
        let parameters = NWParameters.tcp
        guard
            let endpointPort = NWEndpoint.Port(rawValue: port)
        else {
            throw ToolFailure("The port \(port) is not usable.")
        }
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback), port: endpointPort)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "app.honeycrisp.http.accept")

        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            Task {
                await Self.serve(connection: connection, router: router, bearerToken: bearerToken)
            }
        }

        let readyPort: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let resumed = ResumeOnce()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    resumed.run {
                        continuation.resume(returning: listener.port?.rawValue ?? port)
                    }
                case .failed(let error):
                    resumed.run { continuation.resume(throwing: error) }
                case .cancelled:
                    resumed.run {
                        continuation.resume(
                            throwing: ToolFailure("The listener was cancelled before it was ready.")
                        )
                    }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        return LoopbackHTTPServer(listener: listener, port: readyPort)
    }

    public func stop() {
        listener.cancel()
    }

    // MARK: - One connection

    private static func serve(
        connection: NWConnection, router: MCPHTTPRouter, bearerToken: String?
    ) async {
        guard let request = await readRequest(connection: connection) else {
            connection.cancel()
            return
        }
        let response: (status: Int, reason: String, body: Data)
        switch (request.method, request.path) {
        case ("GET", "/health"):
            let body = Data(
                #"{"status":"ok","name":"Honeycrisp","version":"\#(HoneycrispInfo.version)"}"#
                    .utf8)
            response = (200, "OK", body)
        case ("POST", "/mcp"):
            if let bearerToken, request.headers["authorization"] != "Bearer \(bearerToken)" {
                response = (
                    401, "Unauthorized", Data(#"{"error":"A bearer token is required."}"#.utf8)
                )
            } else {
                let routed = await router.handle(
                    body: request.body, clientHeader: request.headers["x-honeycrisp-client"])
                response = (
                    routed.status, routed.status == 202 ? "Accepted" : "OK", routed.body
                )
            }
        default:
            response = (404, "Not Found", Data(#"{"error":"There is nothing here."}"#.utf8))
        }

        var head = "HTTP/1.1 \(response.status) \(response.reason)\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(response.body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var data = Data(head.utf8)
        data.append(response.body)
        connection.send(
            content: data,
            completion: .contentProcessed { _ in
                connection.cancel()
            })
    }

    private struct HTTPRequest {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
    }

    private static func readRequest(connection: NWConnection) async -> HTTPRequest? {
        var buffer = Data()
        let separator = Data("\r\n\r\n".utf8)
        // Read until the header block is complete.
        while buffer.range(of: separator) == nil {
            guard let chunk = await receive(connection: connection), !chunk.isEmpty else {
                return nil
            }
            buffer.append(chunk)
            if buffer.count > 1_048_576 { return nil }
        }
        guard let headerRange = buffer.range(of: separator) else { return nil }
        let headText = String(decoding: buffer[..<headerRange.lowerBound], as: UTF8.self)
        var lines = headText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].lowercased()
            headers[name] = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
        }

        var body = Data(buffer[headerRange.upperBound...])
        // 16 MB is far beyond any sane MCP request and bounds memory.
        let expected = min(max(Int(headers["content-length"] ?? "0") ?? 0, 0), 16_777_216)
        while body.count < expected {
            guard let chunk = await receive(connection: connection), !chunk.isEmpty else { break }
            body.append(chunk)
        }
        return HTTPRequest(
            method: String(requestLine[0]),
            path: String(requestLine[1]),
            headers: headers,
            body: Data(body.prefix(expected))
        )
    }

    private static func receive(connection: NWConnection) async -> Data? {
        await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
                data, _, _, _ in
                continuation.resume(returning: data)
            }
        }
    }
}

/// Lets NWListener's repeated state callbacks resume a continuation once.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ work: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        work()
    }
}

/// The stdio-to-HTTP bridge core: forward each JSON-RPC line, remember the
/// client name from initialize so every later request carries it, write
/// back responses, and synthesize an error when the hub stops answering so
/// the client never hangs.
public enum MCPProxy {
    public static func run(
        lines: AsyncStream<String>,
        post: @Sendable (Data, String?) async throws -> Data?,
        write: @Sendable (String) async -> Void
    ) async {
        var clientName: String?
        for await line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if clientName == nil, let name = initializeClientName(in: trimmed) {
                clientName = name
            }
            do {
                if let response = try await post(Data(trimmed.utf8), clientName),
                    !response.isEmpty
                {
                    await write(String(decoding: response, as: UTF8.self))
                }
            } catch {
                if let id = requestID(in: trimmed) {
                    await write(
                        #"{"jsonrpc":"2.0","id":\#(id),"error":{"code":-32603,"message":"The Honeycrisp app is not reachable. Open Honeycrisp and try again."}}"#
                    )
                }
            }
        }
    }

    private struct Peek: Decodable {
        struct Params: Decodable {
            struct ClientInfo: Decodable {
                let name: String?
            }
            let clientInfo: ClientInfo?
        }
        let id: Value?
        let method: String?
        let params: Params?
    }

    private static func initializeClientName(in line: String) -> String? {
        guard let peek = try? JSONDecoder().decode(Peek.self, from: Data(line.utf8)),
            peek.method == "initialize"
        else { return nil }
        return peek.params?.clientInfo?.name
    }

    /// The id rendered back out as JSON (numbers stay numbers, strings stay
    /// quoted strings).
    private static func requestID(in line: String) -> String? {
        guard let peek = try? JSONDecoder().decode(Peek.self, from: Data(line.utf8)),
            let id = peek.id
        else { return nil }
        switch id {
        case .int(let value): return String(value)
        case .string(let value): return "\"\(value)\""
        default: return nil
        }
    }

    /// Whether the hub is answering on this port.
    public static func hubIsReachable(port: Int) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        guard let (_, response) = try? await URLSession.shared.data(for: request) else {
            return false
        }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }
}
