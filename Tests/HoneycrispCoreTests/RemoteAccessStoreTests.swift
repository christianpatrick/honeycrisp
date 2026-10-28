import Foundation
import Testing
import HoneycrispCore

@Suite("Remote access store")
struct RemoteAccessStoreTests {
    private let resource = "https://mac.example.ts.net/mcp"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func passkey(_ id: String = "cred") -> PasskeyCredential {
        PasskeyCredential(
            id: id, publicKey: Data([4, 1, 2]), signCount: 0,
            relyingPartyID: "mac.example.ts.net", createdAt: now)
    }

    @Test("passkeys, clients, and grants survive a reload")
    func survivesReload() async throws {
        let url = tempStoreURL("remote-access.json")
        let store = RemoteAccessStore(fileURL: url)
        try await store.addPasskey(passkey())
        let client = try #require(
            await store.registerClient(
                name: "Claude", redirectURIs: ["https://claude.ai/api/mcp/auth_callback"], now: now))
        let tokens = await store.createGrant(client: client, resource: resource, now: now)

        let reloaded = RemoteAccessStore(fileURL: url)
        #expect(await reloaded.passkeys() == [passkey()])
        #expect(await reloaded.client(id: client.id) == client)
        #expect(await reloaded.grants().map(\.clientName) == ["Claude"])
        #expect(
            await reloaded.validate(accessToken: tokens.accessToken, resource: resource, now: now)
                != nil)
    }

    @Test("the file is readable by its owner only and holds no raw tokens")
    func filePrivacy() async throws {
        let url = tempStoreURL("remote-access.json")
        let store = RemoteAccessStore(fileURL: url)
        let client = try #require(
            await store.registerClient(name: "Claude", redirectURIs: ["https://a.example/cb"], now: now))
        let tokens = await store.createGrant(client: client, resource: resource, now: now)

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let contents = try String(contentsOf: url, encoding: .utf8)
        #expect(!contents.contains(tokens.accessToken))
        #expect(!contents.contains(tokens.refreshToken))
    }

    @Test("tokens carry their prefixes and expire on schedule")
    func expiry() async throws {
        let store = RemoteAccessStore(fileURL: tempStoreURL("remote-access.json"))
        let client = try #require(
            await store.registerClient(name: "Claude", redirectURIs: ["https://a.example/cb"], now: now))
        let tokens = await store.createGrant(client: client, resource: resource, now: now)
        #expect(tokens.accessToken.hasPrefix("hc_at_"))
        #expect(tokens.refreshToken.hasPrefix("hc_rt_"))
        #expect(tokens.expiresIn == 3600)

        #expect(
            await store.validate(
                accessToken: tokens.accessToken, resource: resource, now: now + 3599) != nil)
        #expect(
            await store.validate(
                accessToken: tokens.accessToken, resource: resource, now: now + 3601) == nil)
        #expect(
            await store.validate(
                accessToken: tokens.accessToken, resource: "https://other.example/mcp", now: now)
                == nil)
    }

    @Test("refreshing rotates both tokens and retires the old ones")
    func rotation() async throws {
        let store = RemoteAccessStore(fileURL: tempStoreURL("remote-access.json"))
        let client = try #require(
            await store.registerClient(name: "Claude", redirectURIs: ["https://a.example/cb"], now: now))
        let first = await store.createGrant(client: client, resource: resource, now: now)
        let second = try #require(
            await store.refresh(
                refreshToken: first.refreshToken, clientID: client.id, resource: resource,
                now: now + 60))
        #expect(second.accessToken != first.accessToken)
        #expect(second.refreshToken != first.refreshToken)
        #expect(
            await store.refresh(
                refreshToken: first.refreshToken, clientID: client.id, resource: resource,
                now: now + 61) == nil)
        #expect(
            await store.validate(accessToken: first.accessToken, resource: resource, now: now + 61)
                == nil)
        #expect(
            await store.validate(accessToken: second.accessToken, resource: resource, now: now + 61)
                != nil)
    }

    @Test("a refresh token works for its own client within thirty days of its last use")
    func refreshRules() async throws {
        let store = RemoteAccessStore(fileURL: tempStoreURL("remote-access.json"))
        let client = try #require(
            await store.registerClient(name: "Claude", redirectURIs: ["https://a.example/cb"], now: now))
        let tokens = await store.createGrant(client: client, resource: resource, now: now)
        #expect(
            await store.refresh(
                refreshToken: tokens.refreshToken, clientID: "someone-else", resource: resource,
                now: now) == nil)
        let day: TimeInterval = 86_400
        let renewed = try #require(
            await store.refresh(
                refreshToken: tokens.refreshToken, clientID: client.id, resource: resource,
                now: now + 29 * day))
        #expect(
            await store.refresh(
                refreshToken: renewed.refreshToken, clientID: client.id, resource: resource,
                now: now + 29 * day + 31 * day) == nil)
    }

    @Test("revoking a grant kills its tokens at once")
    func revoke() async throws {
        let store = RemoteAccessStore(fileURL: tempStoreURL("remote-access.json"))
        let client = try #require(
            await store.registerClient(name: "Claude", redirectURIs: ["https://a.example/cb"], now: now))
        let tokens = await store.createGrant(client: client, resource: resource, now: now)
        let grant = try #require(await store.grants().first)
        await store.revokeGrant(id: grant.id)
        #expect(await store.grants().isEmpty)
        #expect(
            await store.validate(accessToken: tokens.accessToken, resource: resource, now: now)
                == nil)
        #expect(
            await store.refresh(
                refreshToken: tokens.refreshToken, clientID: client.id, resource: resource, now: now)
                == nil)
    }

    @Test("the store keeps fifty clients and drops the oldest ones without a grant")
    func clientCap() async throws {
        let store = RemoteAccessStore(fileURL: tempStoreURL("remote-access.json"))
        let kept = try #require(
            await store.registerClient(name: "Kept", redirectURIs: ["https://a.example/cb"], now: now))
        _ = await store.createGrant(client: kept, resource: resource, now: now)
        var ids: [String] = []
        for index in 0..<60 {
            let client = try #require(
                await store.registerClient(
                    name: "Client \(index)", redirectURIs: ["https://a.example/cb"],
                    now: now + Double(index + 1)))
            ids.append(client.id)
        }
        #expect(await store.clientCount() == 50)
        #expect(await store.client(id: kept.id) != nil)
        #expect(await store.client(id: ids[0]) == nil)
        #expect(await store.client(id: ids[59]) != nil)
    }

    @Test("passkeys update their count, refuse duplicates, and clear")
    func passkeys() async throws {
        let store = RemoteAccessStore(fileURL: tempStoreURL("remote-access.json"))
        try await store.addPasskey(passkey("one"))
        await #expect(throws: (any Error).self) { try await store.addPasskey(passkey("one")) }
        await store.updateSignCount(id: "one", count: 7)
        #expect(await store.passkeys().first?.signCount == 7)
        await store.removeAllPasskeys()
        #expect(await store.passkeys().isEmpty)
    }

    @Test("grants past their refresh expiry stop pinning clients and stop listing")
    func expiredGrants() async throws {
        let store = RemoteAccessStore(fileURL: tempStoreURL("remote-access.json"))
        for index in 0..<50 {
            let client = try #require(
                await store.registerClient(
                    name: "Client \(index)", redirectURIs: ["https://a.example/cb"], now: now))
            _ = await store.createGrant(client: client, resource: resource, now: now)
        }
        #expect(
            await store.registerClient(
                name: "Late", redirectURIs: ["https://a.example/cb"], resource: resource,
                now: now + 60) == nil)

        // Thirty days on, every refresh token has expired and nothing can
        // use those grants again.
        let later = now + 31 * 86_400
        #expect(
            await store.registerClient(
                name: "New", redirectURIs: ["https://a.example/cb"], resource: resource,
                now: later) != nil)
        #expect(await store.liveGrants(resource: resource, now: later).isEmpty)
    }

    @Test("grants made for another public URL are dropped for good")
    func oldResourceGrants() async throws {
        let store = RemoteAccessStore(fileURL: tempStoreURL("remote-access.json"))
        let client = try #require(
            await store.registerClient(name: "Old", redirectURIs: ["https://a.example/cb"], now: now))
        _ = await store.createGrant(client: client, resource: "https://old.example/mcp", now: now)
        let current = try #require(
            await store.registerClient(name: "Current", redirectURIs: ["https://a.example/cb"], now: now))
        _ = await store.createGrant(client: current, resource: resource, now: now)

        let live = await store.liveGrants(resource: resource, now: now)
        #expect(live.map(\.clientName) == ["Current"])
        #expect(await store.grants().map(\.clientName) == ["Current"])
    }

    @Test("without a public URL only expiry decides which grants are live")
    func liveWithoutResource() async throws {
        let store = RemoteAccessStore(fileURL: tempStoreURL("remote-access.json"))
        let client = try #require(
            await store.registerClient(name: "Kept", redirectURIs: ["https://a.example/cb"], now: now))
        _ = await store.createGrant(client: client, resource: "https://old.example/mcp", now: now)
        #expect(await store.liveGrants(resource: nil, now: now).count == 1)
        #expect(await store.liveGrants(resource: nil, now: now + 31 * 86_400).isEmpty)
    }
}
