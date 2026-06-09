import Foundation
import Testing
import HoneycrispCore

private actor Recorder {
    private(set) var posts: [(body: String, client: String?)] = []
    private(set) var writes: [String] = []
    var responses: [Data?] = []
    var shouldThrow = false

    func setResponses(_ responses: [Data?]) { self.responses = responses }
    func setShouldThrow(_ value: Bool) { shouldThrow = value }

    func post(_ data: Data, client: String?) throws -> Data? {
        posts.append((String(decoding: data, as: UTF8.self), client))
        if shouldThrow { throw ToolFailure("hub went away") }
        return responses.isEmpty ? nil : responses.removeFirst()
    }

    func write(_ line: String) {
        writes.append(line)
    }
}

private func lines(_ items: [String]) -> AsyncStream<String> {
    AsyncStream { continuation in
        for item in items { continuation.yield(item) }
        continuation.finish()
    }
}

private let initializeLine =
    #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"Claude Desktop","version":"1.0"}}}"#

@Suite("MCP proxy")
struct MCPProxyTests {
    @Test("forwards lines, writes responses, and stamps the client after initialize")
    func forwards() async {
        let recorder = Recorder()
        await recorder.setResponses([Data("{\"id\":1}".utf8), Data("{\"id\":2}".utf8)])
        await MCPProxy.run(
            lines: lines([initializeLine, #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#]),
            post: { try await recorder.post($0, client: $1) },
            write: { await recorder.write($0) }
        )
        let posts = await recorder.posts
        #expect(posts.count == 2)
        #expect(posts.first?.client == "Claude Desktop")
        #expect(posts.last?.client == "Claude Desktop")
        #expect(await recorder.writes == ["{\"id\":1}", "{\"id\":2}"])
    }

    @Test("empty replies to notifications write nothing")
    func notifications() async {
        let recorder = Recorder()
        await recorder.setResponses([nil])
        await MCPProxy.run(
            lines: lines([#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#]),
            post: { try await recorder.post($0, client: $1) },
            write: { await recorder.write($0) }
        )
        #expect(await recorder.writes.isEmpty)
    }

    @Test("a failing hub synthesizes a JSON-RPC error with the original id")
    func hubFailure() async {
        let recorder = Recorder()
        await recorder.setShouldThrow(true)
        await MCPProxy.run(
            lines: lines([#"{"jsonrpc":"2.0","id":7,"method":"tools/list"}"#]),
            post: { try await recorder.post($0, client: $1) },
            write: { await recorder.write($0) }
        )
        let writes = await recorder.writes
        #expect(writes.count == 1)
        #expect(writes.first?.contains("-32603") == true)
        #expect(writes.first?.contains("\"id\":7") == true)
    }
}
