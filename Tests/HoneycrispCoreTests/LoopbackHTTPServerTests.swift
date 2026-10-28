import Foundation
import MCP
import Network
import Testing
import HoneycrispCore

@Suite("Loopback HTTP server", .serialized)
struct LoopbackHTTPServerTests {
    private func makeServer(bearerToken: String?) async throws -> LoopbackHTTPServer {
        let gateway = ToolGateway(
            configProvider: { .default },
            executor: CapturingExecutor(),
            audit: AuditStore(fileURL: tempStoreURL("audit.jsonl")),
            approvals: nil
        )
        let router = MCPHTTPRouter(gateway: gateway, clients: ClientRegistry())
        return try await LoopbackHTTPServer.start(port: 0, bearerToken: bearerToken, router: router)
    }

    private func initializeData() -> Data {
        Data(
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"\#(Version.latest)","capabilities":{},"clientInfo":{"name":"Socket Test","version":"1.0"}}}"#
            .utf8)
    }

    @Test("health answers with the version and no auth")
    func health() async throws {
        let server = try await makeServer(bearerToken: "sesame")
        defer { server.stop() }
        let url = URL(string: "http://127.0.0.1:\(server.port)/health")!
        let (data, response) = try await URLSession.shared.data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self).contains(HoneycrispInfo.version))
    }

    @Test("mcp requires the bearer token when one is configured")
    func bearer() async throws {
        let server = try await makeServer(bearerToken: "sesame")
        defer { server.stop() }
        let url = URL(string: "http://127.0.0.1:\(server.port)/mcp")!

        var anonymous = URLRequest(url: url)
        anonymous.httpMethod = "POST"
        anonymous.httpBody = initializeData()
        let (_, denied) = try await URLSession.shared.data(for: anonymous)
        #expect((denied as? HTTPURLResponse)?.statusCode == 401)

        var authorized = anonymous
        authorized.setValue("Bearer sesame", forHTTPHeaderField: "Authorization")
        let (data, allowed) = try await URLSession.shared.data(for: authorized)
        #expect((allowed as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self).contains("Honeycrisp"))
    }

    @Test("two initializes round-trip end to end without auth configured")
    func repeatedInitialize() async throws {
        let server = try await makeServer(bearerToken: nil)
        defer { server.stop() }
        let url = URL(string: "http://127.0.0.1:\(server.port)/mcp")!
        for _ in 0..<2 {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = initializeData()
            let (data, response) = try await URLSession.shared.data(for: request)
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            #expect(String(decoding: data, as: UTF8.self).contains("serverInfo"))
        }
    }

    @Test("unknown paths are 404")
    func notFound() async throws {
        let server = try await makeServer(bearerToken: nil)
        defer { server.stop() }
        let url = URL(string: "http://127.0.0.1:\(server.port)/nope")!
        let (_, response) = try await URLSession.shared.data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 404)
    }

    @Test("the local port refuses a request that came through a proxy")
    func refusesForwarded() async throws {
        let server = try await makeServer(bearerToken: nil)
        defer { server.stop() }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/mcp")!)
        request.httpMethod = "POST"
        request.httpBody = initializeData()
        request.setValue("203.0.113.9", forHTTPHeaderField: "X-Forwarded-For")
        let (_, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 403)
    }

    @Test("a handler server answers with the handler's response and reads chunked bodies whole")
    func handlerServer() async throws {
        let server = try await LoopbackHTTPServer.start(port: 0) { request in
            HTTPResponse(
                status: 201, headers: ["Content-Type": "text/plain", "X-Echo": request.path],
                body: request.body)
        }
        defer { server.stop() }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/echo?x=1")!)
        request.httpMethod = "POST"
        // A body stream with no length goes out chunked.
        request.httpBodyStream = InputStream(data: Data("hello chunks".utf8))
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        #expect(http?.statusCode == 201)
        #expect(http?.value(forHTTPHeaderField: "X-Echo") == "/echo")
        #expect(String(decoding: data, as: UTF8.self) == "hello chunks")
    }

    @Test("a request that stops arriving is dropped at the read deadline", .timeLimit(.minutes(1)))
    func readDeadline() async throws {
        let server = try await LoopbackHTTPServer.start(port: 0, readTimeout: 0.3) { _ in
            HTTPResponse(status: 200)
        }
        defer { server.stop() }
        let connection = NWConnection(
            host: .ipv4(.loopback), port: try #require(NWEndpoint.Port(rawValue: server.port)),
            using: .tcp)
        connection.start(queue: .global())
        // The headers promise ten bytes of body and only three ever come.
        connection.send(
            content: Data("POST /x HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 10\r\n\r\nabc".utf8),
            completion: .idempotent)
        let started = Date()
        let answer: Data? = await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
                continuation.resume(returning: data)
            }
        }
        connection.cancel()
        #expect(answer?.isEmpty ?? true)
        #expect(Date().timeIntervalSince(started) < 10)
    }
}
