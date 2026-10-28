import Foundation
import Testing
import HoneycrispCore

@Suite("HTTP messages")
struct HTTPMessageTests {
    @Test("the path and query split and the query decodes")
    func query() {
        let request = getRequest("/authorize?state=a+b&redirect_uri=https%3A%2F%2Fclaude.ai%2Fcb&empty=")
        #expect(request.path == "/authorize")
        #expect(
            request.query
                == ["state": "a b", "redirect_uri": "https://claude.ai/cb", "empty": ""])
        #expect(getRequest("/mcp").query == [:])
    }

    @Test("form bodies decode plus signs and percent escapes")
    func form() {
        let fields = HTTPForm.decode(Data("grant_type=authorization_code&code_verifier=a%2Bb+c".utf8))
        #expect(fields == ["grant_type": "authorization_code", "code_verifier": "a+b c"])
    }

    @Test("a repeated parameter makes the whole set invalid")
    func duplicates() {
        #expect(HTTPForm.decode(Data("code=a&code=b".utf8)) == nil)
        #expect(getRequest("/authorize?client_id=a&client_id=b").query == nil)
    }

    @Test("a chunked body decodes whole")
    func chunked() throws {
        let raw = Data("4\r\nWiki\r\n5;note=x\r\npedia\r\n0\r\n\r\n".utf8)
        #expect(try ChunkedBody.decode(raw) == Data("Wikipedia".utf8))
    }

    @Test("an incomplete chunked body asks for more")
    func incomplete() throws {
        #expect(try ChunkedBody.decode(Data("4\r\nWi".utf8)) == nil)
        #expect(try ChunkedBody.decode(Data("4\r\nWiki\r\n".utf8)) == nil)
        #expect(try ChunkedBody.decode(Data("4\r\nWiki\r\n0\r\n".utf8)) == nil)
    }

    @Test("a malformed chunk size is refused")
    func malformed() {
        #expect(throws: (any Error).self) { try ChunkedBody.decode(Data("zz\r\nWiki\r\n0\r\n\r\n".utf8)) }
        #expect(throws: (any Error).self) { try ChunkedBody.decode(Data("4\r\nWikiX\r\n0\r\n\r\n".utf8)) }
    }

    @Test("the local guard accepts loopback hosts with and without ports")
    func guardAccepts() {
        #expect(LocalRequestGuard.allows(headers: ["host": "127.0.0.1:41117"]))
        #expect(LocalRequestGuard.allows(headers: ["host": "localhost:41117"]))
        #expect(LocalRequestGuard.allows(headers: ["host": "LOCALHOST"]))
        #expect(LocalRequestGuard.allows(headers: ["host": "[::1]:41117"]))
        #expect(LocalRequestGuard.allows(headers: [:]))
    }

    @Test("the local guard refuses other hosts and forwarded requests")
    func guardRefuses() {
        #expect(!LocalRequestGuard.allows(headers: ["host": "mac.example.ts.net"]))
        #expect(!LocalRequestGuard.allows(headers: ["host": "evil.example:41117"]))
        #expect(!LocalRequestGuard.allows(headers: ["host": "127.0.0.1.evil.example"]))
        #expect(
            !LocalRequestGuard.allows(headers: ["host": "127.0.0.1:41117", "x-forwarded-for": "1.2.3.4"]))
        #expect(
            !LocalRequestGuard.allows(headers: ["host": "127.0.0.1:41117", "forwarded": "for=1.2.3.4"]))
    }
}
