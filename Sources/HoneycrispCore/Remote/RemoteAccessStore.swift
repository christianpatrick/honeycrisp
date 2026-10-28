import CryptoKit
import Foundation

/// A client that registered itself through dynamic client registration.
/// Every one is public: it holds no secret, and PKCE protects its codes.
public struct RemoteClient: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let redirectURIs: [String]
    public let createdAt: Date
}

/// One connection the owner allowed with a passkey. Its tokens exist on
/// disk only as SHA-256 hashes.
public struct RemoteGrant: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let clientID: String
    public let clientName: String
    public let resource: String
    public let createdAt: Date
    var accessTokenHash: String
    var accessExpiresAt: Date
    var refreshTokenHash: String
    var refreshExpiresAt: Date
}

/// What the token endpoint hands a client.
public struct IssuedTokens: Sendable, Equatable {
    public let accessToken: String
    public let refreshToken: String
    public let expiresIn: Int
}

public struct DuplicatePasskey: Error {}

/// Remote access state that outlives a restart: the owner's passkeys,
/// registered clients, and grants, in remote-access.json beside the
/// config, readable by the owner only (GH-16).
public actor RemoteAccessStore {
    static let accessLifetime: TimeInterval = 3600
    static let refreshLifetime: TimeInterval = 30 * 86_400
    static let maxClients = 50

    private struct State: Codable {
        var passkeys: [PasskeyCredential] = []
        var clients: [RemoteClient] = []
        var grants: [RemoteGrant] = []
    }

    private let fileURL: URL
    private var state: State

    public init(fileURL: URL) {
        self.fileURL = fileURL
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: fileURL),
            let loaded = try? decoder.decode(State.self, from: data)
        {
            state = loaded
        } else {
            state = State()
        }
    }

    // MARK: - Passkeys

    public func passkeys() -> [PasskeyCredential] {
        state.passkeys
    }

    public func addPasskey(_ passkey: PasskeyCredential) throws {
        guard !state.passkeys.contains(where: { $0.id == passkey.id }) else {
            throw DuplicatePasskey()
        }
        state.passkeys.append(passkey)
        save()
    }

    public func updateSignCount(id: String, count: UInt32) {
        guard let index = state.passkeys.firstIndex(where: { $0.id == id }) else { return }
        state.passkeys[index].signCount = count
        save()
    }

    public func removeAllPasskeys() {
        state.passkeys = []
        save()
    }

    // MARK: - Clients

    /// Registers a client, or returns nil when fifty clients all hold live
    /// grants. Claude registers a new client on every fresh connection, so
    /// dead grants go first, then the oldest clients without a grant make
    /// room.
    public func registerClient(
        name: String, redirectURIs: [String], resource: String? = nil, now: Date
    ) -> RemoteClient? {
        dropDeadGrants(resource: resource, now: now)
        let granted = Set(state.grants.map(\.clientID))
        while state.clients.count >= Self.maxClients {
            guard let oldest = state.clients.firstIndex(where: { !granted.contains($0.id) }) else {
                return nil
            }
            state.clients.remove(at: oldest)
        }
        let client = RemoteClient(
            id: "hc_client_" + Base64URL.encode(RemoteSecret.bytes(16)),
            name: name,
            redirectURIs: redirectURIs,
            createdAt: now
        )
        state.clients.append(client)
        save()
        return client
    }

    public func client(id: String) -> RemoteClient? {
        state.clients.first { $0.id == id }
    }

    public func clientCount() -> Int {
        state.clients.count
    }

    // MARK: - Grants and tokens

    public func grants() -> [RemoteGrant] {
        state.grants
    }

    /// The grants a client can still use, for Settings. Dead ones are
    /// dropped for good first.
    public func liveGrants(resource: String?, now: Date) -> [RemoteGrant] {
        dropDeadGrants(resource: resource, now: now)
        return state.grants
    }

    /// A grant past its refresh expiry, or made for another public URL, can
    /// never be used again: its access token always expires first. Keeping
    /// it would pin its client and list it as connected forever.
    private func dropDeadGrants(resource: String?, now: Date) {
        let before = state.grants.count
        state.grants.removeAll { grant in
            now >= grant.refreshExpiresAt || (resource.map { $0 != grant.resource } ?? false)
        }
        if state.grants.count != before { save() }
    }

    public func createGrant(client: RemoteClient, resource: String, now: Date) -> IssuedTokens {
        let access = RemoteSecret.token(prefix: "hc_at_")
        let refresh = RemoteSecret.token(prefix: "hc_rt_")
        state.grants.append(
            RemoteGrant(
                id: UUID(),
                clientID: client.id,
                clientName: client.name,
                resource: resource,
                createdAt: now,
                accessTokenHash: Self.hash(access),
                accessExpiresAt: now + Self.accessLifetime,
                refreshTokenHash: Self.hash(refresh),
                refreshExpiresAt: now + Self.refreshLifetime
            ))
        save()
        return IssuedTokens(
            accessToken: access, refreshToken: refresh, expiresIn: Int(Self.accessLifetime))
    }

    /// Rotates a grant's tokens. The old refresh token and the old access
    /// token stop working in the same step that issues the new ones.
    public func refresh(refreshToken: String, clientID: String, resource: String?, now: Date)
        -> IssuedTokens?
    {
        let hash = Self.hash(refreshToken)
        guard let index = state.grants.firstIndex(where: { $0.refreshTokenHash == hash }) else {
            return nil
        }
        let grant = state.grants[index]
        guard grant.clientID == clientID, now < grant.refreshExpiresAt else { return nil }
        if let resource, resource != grant.resource { return nil }

        let access = RemoteSecret.token(prefix: "hc_at_")
        let refresh = RemoteSecret.token(prefix: "hc_rt_")
        state.grants[index].accessTokenHash = Self.hash(access)
        state.grants[index].accessExpiresAt = now + Self.accessLifetime
        state.grants[index].refreshTokenHash = Self.hash(refresh)
        state.grants[index].refreshExpiresAt = now + Self.refreshLifetime
        save()
        return IssuedTokens(
            accessToken: access, refreshToken: refresh, expiresIn: Int(Self.accessLifetime))
    }

    /// The grant behind an access token, when the token is current and was
    /// issued for this exact resource.
    public func validate(accessToken: String, resource: String, now: Date) -> RemoteGrant? {
        let hash = Self.hash(accessToken)
        guard let grant = state.grants.first(where: { $0.accessTokenHash == hash }),
            now < grant.accessExpiresAt, grant.resource == resource
        else { return nil }
        return grant
    }

    public func revokeGrant(id: UUID) {
        state.grants.removeAll { $0.id == id }
        save()
    }

    // MARK: - Disk

    static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Best effort, like the config: a failed write leaves the in-memory
    /// state working until the next change tries again.
    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(state) else { return }
        let manager = FileManager.default
        try? manager.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (try? data.write(to: fileURL, options: .atomic)) != nil else { return }
        try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
