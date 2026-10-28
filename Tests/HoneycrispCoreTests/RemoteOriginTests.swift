import Foundation
import Testing
import HoneycrispCore

@Suite("Remote origin")
struct RemoteOriginTests {
    @Test("an https origin gives the issuer, resource, and relying party")
    func parts() throws {
        let origin = try #require(RemoteOrigin(publicURL: "https://mac.example.ts.net"))
        #expect(origin.origin == "https://mac.example.ts.net")
        #expect(origin.issuer == "https://mac.example.ts.net")
        #expect(origin.resource == "https://mac.example.ts.net/mcp")
        #expect(origin.relyingPartyID == "mac.example.ts.net")
        #expect(
            origin.resourceMetadataURL
                == "https://mac.example.ts.net/.well-known/oauth-protected-resource")
    }

    @Test("a trailing slash or /mcp and surrounding spaces give the same origin")
    func normalizes() {
        let plain = RemoteOrigin(publicURL: "https://mac.example.ts.net")
        #expect(plain != nil)
        #expect(RemoteOrigin(publicURL: "https://mac.example.ts.net/") == plain)
        #expect(RemoteOrigin(publicURL: "https://mac.example.ts.net/mcp") == plain)
        #expect(RemoteOrigin(publicURL: "  https://mac.example.ts.net/mcp/ ") == plain)
        #expect(RemoteOrigin(publicURL: "HTTPS://Mac.Example.TS.net") == plain)
        #expect(RemoteOrigin(publicURL: "https://mac.example.ts.net:443") == plain)
    }

    @Test("a non-default port survives")
    func port() {
        let origin = RemoteOrigin(publicURL: "https://mac.example.ts.net:8443/")
        #expect(origin?.origin == "https://mac.example.ts.net:8443")
        #expect(origin?.resource == "https://mac.example.ts.net:8443/mcp")
        #expect(origin?.relyingPartyID == "mac.example.ts.net")
    }

    @Test("anything but a bare https origin is refused")
    func refuses() {
        #expect(RemoteOrigin(publicURL: "http://mac.example.ts.net") == nil)
        #expect(RemoteOrigin(publicURL: "https://mac.example.ts.net/other") == nil)
        #expect(RemoteOrigin(publicURL: "https://mac.example.ts.net/?a=b") == nil)
        #expect(RemoteOrigin(publicURL: "https://mac.example.ts.net/#top") == nil)
        #expect(RemoteOrigin(publicURL: "https://me@mac.example.ts.net") == nil)
        #expect(RemoteOrigin(publicURL: "https://") == nil)
        #expect(RemoteOrigin(publicURL: "mac.example.ts.net") == nil)
        #expect(RemoteOrigin(publicURL: "") == nil)
    }
}
