import CryptoKit
import Foundation

/// Everything the remote port answers: OAuth discovery, client
/// registration, consent with a passkey, tokens, passkey setup, and /mcp
/// for valid access tokens (GH-16). Socket-free, so tests drive it
/// directly. Ceremony state lives here in memory; anything that must
/// survive a restart lives in the store.
public actor RemoteAccessServer {
    /// Runs one MCP request for the client named in its grant.
    public typealias MCPHandler = @Sendable (_ body: Data, _ client: String) async -> HTTPResponse

    static let setupLifetime: TimeInterval = 600
    static let requestLifetime: TimeInterval = 600
    static let codeLifetime: TimeInterval = 120
    static let maxPending = 100

    private struct PendingSetup {
        var challenge: Data?
        let expiresAt: Date
    }

    private struct PendingAuthorization {
        let clientID: String
        let redirectURI: String
        let codeChallenge: String
        let state: String?
        let challenge: Data
        let expiresAt: Date
    }

    private struct IssuedCode {
        let clientID: String
        let redirectURI: String
        let codeChallenge: String
        let expiresAt: Date
    }

    private let origin: RemoteOrigin
    private let store: RemoteAccessStore
    private let mcp: MCPHandler
    private let now: @Sendable () -> Date
    private var setups: [String: PendingSetup] = [:]
    private var authorizations: [String: PendingAuthorization] = [:]
    private var codes: [String: IssuedCode] = [:]

    public init(
        origin: RemoteOrigin,
        store: RemoteAccessStore,
        mcp: @escaping MCPHandler,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.origin = origin
        self.store = store
        self.mcp = mcp
        self.now = now
    }

    /// A one-time link that adds a passkey, for Settings to open or copy.
    public func makeSetupLink() -> URL {
        prune()
        let code = Base64URL.encode(RemoteSecret.bytes(16))
        Self.insert(PendingSetup(expiresAt: now() + Self.setupLifetime), for: code, into: &setups) {
            $0.expiresAt
        }
        return URL(string: origin.origin + "/setup?code=" + code)!
    }

    public func handle(_ request: HTTPRequest) async -> HTTPResponse {
        switch (request.method, request.path) {
        case ("GET", "/.well-known/oauth-protected-resource"),
            ("GET", "/.well-known/oauth-protected-resource/mcp"):
            return resourceMetadata()
        case ("GET", "/.well-known/oauth-authorization-server"):
            return serverMetadata()
        case ("POST", "/register"):
            return await register(request)
        case ("GET", "/authorize"):
            return await authorizePage(request)
        case ("POST", "/authorize"):
            return await authorizeDecision(request)
        case ("POST", "/token"):
            return await token(request)
        case ("GET", "/setup"):
            return await setupPage(request)
        case ("POST", "/setup"):
            return await saveSetup(request)
        case (_, "/mcp"):
            return await resource(request)
        default:
            return .json(404, ["error": "not_found", "error_description": "There is nothing here."])
        }
    }

    // MARK: - Discovery

    private func resourceMetadata() -> HTTPResponse {
        .json(
            200,
            [
                "resource": origin.resource,
                "authorization_servers": [origin.issuer],
                "bearer_methods_supported": ["header"],
                "resource_name": "Honeycrisp",
            ])
    }

    private func serverMetadata() -> HTTPResponse {
        .json(
            200,
            [
                "issuer": origin.issuer,
                "authorization_endpoint": origin.origin + "/authorize",
                "token_endpoint": origin.origin + "/token",
                "registration_endpoint": origin.origin + "/register",
                "response_types_supported": ["code"],
                "grant_types_supported": ["authorization_code", "refresh_token"],
                "code_challenge_methods_supported": ["S256"],
                "token_endpoint_auth_methods_supported": ["none"],
                "authorization_response_iss_parameter_supported": true,
            ])
    }

    // MARK: - Registration

    private func register(_ request: HTTPRequest) async -> HTTPResponse {
        func failure(_ error: String, _ description: String) -> HTTPResponse {
            .json(400, ["error": error, "error_description": description])
        }
        guard let object = Self.jsonObject(request.body) else {
            return failure("invalid_client_metadata", "The registration must be a JSON object.")
        }
        guard let uris = object["redirect_uris"] as? [String], (1...10).contains(uris.count) else {
            return failure("invalid_redirect_uri", "Send between one and ten redirect URIs.")
        }
        guard uris.allSatisfy(Self.isAllowedRedirect) else {
            return failure(
                "invalid_redirect_uri",
                "Redirect URIs must be https, or http on a loopback address, with no fragment.")
        }
        let name = Self.cleanName(object["client_name"] as? String)
        guard let client = await store.registerClient(name: name, redirectURIs: uris, now: now())
        else {
            return failure(
                "invalid_client_metadata",
                "Honeycrisp already has fifty connected clients. Disconnect one in Settings first.")
        }
        return .json(
            201,
            [
                "client_id": client.id,
                "client_id_issued_at": Int(client.createdAt.timeIntervalSince1970),
                "client_name": client.name,
                "redirect_uris": client.redirectURIs,
                "grant_types": ["authorization_code", "refresh_token"],
                "response_types": ["code"],
                "token_endpoint_auth_method": "none",
            ],
            headers: ["Cache-Control": "no-store"])
    }

    // MARK: - Authorization

    private func authorizePage(_ request: HTTPRequest) async -> HTTPResponse {
        prune()
        guard let query = request.query else {
            return RemotePages.problem(
                400, title: "This sign-in link is broken",
                message: "A parameter appears twice. Start connecting again from your client.")
        }
        // Every error stays on this page. Registration is open, so a
        // registered redirect URI says nothing about who owns it, and
        // redirecting an error there unasked would let anyone bounce a
        // browser off this host (RFC 9700 section 4.11.2). Only the owner's
        // own choice on the consent page sends the browser back.
        guard let clientID = query["client_id"], let client = await store.client(id: clientID) else {
            return RemotePages.problem(
                400, title: "Honeycrisp doesn't know this client",
                message: "Start connecting again from your client so it can register first.")
        }
        guard let redirect = query["redirect_uri"],
            Self.redirect(redirect, matches: client.redirectURIs)
        else {
            return RemotePages.problem(
                400, title: "This sign-in link points somewhere unexpected",
                message:
                    "Its return address doesn't match what the client registered, so Honeycrisp won't send you there."
            )
        }
        func failure(_ message: String) -> HTTPResponse {
            RemotePages.problem(400, title: "This sign-in link is broken", message: message)
        }
        guard query["response_type"] == "code" else {
            return failure("Honeycrisp supports the code flow only. Start connecting again from your client.")
        }
        guard let codeChallenge = query["code_challenge"], Self.isPKCEValue(codeChallenge),
            query["code_challenge_method"] == "S256"
        else {
            return failure(
                "Honeycrisp requires a PKCE code challenge using S256. Start connecting again from your client.")
        }
        if let resource = query["resource"], !matchesResource(resource) {
            return failure("The link asks for a different server than this one.")
        }
        let state = query["state"]

        let passkeys = await store.passkeys().filter { $0.relyingPartyID == origin.relyingPartyID }
        guard !passkeys.isEmpty else { return RemotePages.needsPasskey() }

        let id = Base64URL.encode(RemoteSecret.bytes(16))
        let challenge = RemoteSecret.bytes(32)
        Self.insert(
            PendingAuthorization(
                clientID: client.id, redirectURI: redirect, codeChallenge: codeChallenge,
                state: state, challenge: challenge, expiresAt: now() + Self.requestLifetime),
            for: id, into: &authorizations
        ) { $0.expiresAt }

        let host = URLComponents(string: redirect)?.host ?? redirect
        return RemotePages.consent(
            clientName: client.name,
            redirectHost: host,
            loopback: Self.isLoopbackHost(host),
            data: [
                "request": id,
                "challenge": Base64URL.encode(challenge),
                "rpId": origin.relyingPartyID,
                "allow": passkeys.map(\.id),
            ])
    }

    private func authorizeDecision(_ request: HTTPRequest) async -> HTTPResponse {
        // Taking the request out before any await makes it single use, even
        // if two decisions race.
        guard let object = Self.jsonObject(request.body),
            let id = object["request"] as? String,
            let pending = authorizations.removeValue(forKey: id),
            now() < pending.expiresAt
        else {
            return .json(
                400,
                [
                    "error": "invalid_request",
                    "error_description": "This sign-in expired. Start connecting again from your client.",
                ])
        }
        var parameters: [(String, String)] = []

        guard object["approve"] as? Bool == true else {
            parameters.append(("error", "access_denied"))
            if let state = pending.state { parameters.append(("state", state)) }
            parameters.append(("iss", origin.issuer))
            return .json(200, ["redirect": Self.redirectURL(pending.redirectURI, parameters)])
        }

        guard let credential = object["credential"] as? [String: Any],
            let credentialID = credential["id"] as? String,
            let clientData = Self.base64Field(credential, "clientDataJSON"),
            let authenticatorData = Self.base64Field(credential, "authenticatorData"),
            let signature = Self.base64Field(credential, "signature")
        else {
            return .json(
                400,
                [
                    "error": "invalid_request",
                    "error_description": "The passkey answer was incomplete. Start connecting again from your client.",
                ])
        }
        let count: UInt32
        do {
            count = try WebAuthn.verifyAssertion(
                credentialID: credentialID,
                clientDataJSON: clientData,
                authenticatorData: authenticatorData,
                signature: signature,
                challenge: pending.challenge,
                origin: origin.origin,
                relyingPartyID: origin.relyingPartyID,
                passkeys: await store.passkeys())
        } catch {
            return .json(
                400,
                [
                    "error": "access_denied",
                    "error_description": "That passkey didn't sign in. Start connecting again from your client.",
                ])
        }
        await store.updateSignCount(id: credentialID, count: count)

        let code = RemoteSecret.token()
        Self.insert(
            IssuedCode(
                clientID: pending.clientID, redirectURI: pending.redirectURI,
                codeChallenge: pending.codeChallenge, expiresAt: now() + Self.codeLifetime),
            for: code, into: &codes
        ) { $0.expiresAt }
        parameters.append(("code", code))
        if let state = pending.state { parameters.append(("state", state)) }
        parameters.append(("iss", origin.issuer))
        return .json(
            200, ["redirect": Self.redirectURL(pending.redirectURI, parameters)],
            headers: ["Cache-Control": "no-store"])
    }

    // MARK: - Tokens

    private func token(_ request: HTTPRequest) async -> HTTPResponse {
        guard let form = HTTPForm.decode(request.body) else {
            return tokenError(400, "invalid_request", "A parameter appears twice.")
        }
        switch form["grant_type"] {
        case "authorization_code":
            return await exchangeCode(form)
        case "refresh_token":
            return await refreshTokens(form)
        case nil:
            return tokenError(400, "invalid_request", "grant_type is missing.")
        default:
            return tokenError(
                400, "unsupported_grant_type",
                "Honeycrisp supports authorization_code and refresh_token.")
        }
    }

    private func exchangeCode(_ form: [String: String]) async -> HTTPResponse {
        guard let code = form["code"], let clientID = form["client_id"],
            let redirect = form["redirect_uri"], let verifier = form["code_verifier"]
        else {
            return tokenError(
                400, "invalid_request",
                "code, client_id, redirect_uri, and code_verifier are all required.")
        }
        if let resource = form["resource"], !matchesResource(resource) {
            return tokenError(400, "invalid_target", "That resource is not this Honeycrisp server.")
        }
        // Removing the code first makes it single use whatever happens next.
        guard let issued = codes.removeValue(forKey: code),
            now() < issued.expiresAt,
            issued.clientID == clientID,
            issued.redirectURI == redirect,
            Self.isPKCEValue(verifier),
            Self.pkceChallenge(verifier) == issued.codeChallenge
        else {
            return tokenError(400, "invalid_grant", "That code is not valid.")
        }
        guard let client = await store.client(id: clientID) else {
            return tokenError(401, "invalid_client", "Honeycrisp doesn't know this client.")
        }
        let tokens = await store.createGrant(client: client, resource: origin.resource, now: now())
        return tokenResponse(tokens)
    }

    private func refreshTokens(_ form: [String: String]) async -> HTTPResponse {
        guard let refresh = form["refresh_token"], let clientID = form["client_id"] else {
            return tokenError(400, "invalid_request", "refresh_token and client_id are required.")
        }
        if let resource = form["resource"], !matchesResource(resource) {
            return tokenError(400, "invalid_target", "That resource is not this Honeycrisp server.")
        }
        // Passing the current resource means a grant made under an old
        // public URL can't be refreshed into tokens that look current.
        guard
            let tokens = await store.refresh(
                refreshToken: refresh, clientID: clientID, resource: origin.resource, now: now())
        else {
            return tokenError(400, "invalid_grant", "That refresh token is not valid.")
        }
        return tokenResponse(tokens)
    }

    private func tokenResponse(_ tokens: IssuedTokens) -> HTTPResponse {
        .json(
            200,
            [
                "access_token": tokens.accessToken,
                "token_type": "Bearer",
                "expires_in": tokens.expiresIn,
                "refresh_token": tokens.refreshToken,
            ],
            headers: ["Cache-Control": "no-store", "Pragma": "no-cache"])
    }

    private func tokenError(_ status: Int, _ error: String, _ description: String) -> HTTPResponse {
        .json(
            status, ["error": error, "error_description": description],
            headers: ["Cache-Control": "no-store", "Pragma": "no-cache"])
    }

    // MARK: - Passkey setup

    private func setupPage(_ request: HTTPRequest) async -> HTTPResponse {
        prune()
        guard let code = request.query?["code"], var setup = setups[code], now() < setup.expiresAt
        else {
            return RemotePages.problem(
                400, title: "This setup link expired",
                message: "Open Honeycrisp's settings on your Mac and choose Add a passkey again.")
        }
        let challenge = RemoteSecret.bytes(32)
        setup.challenge = challenge
        setups[code] = setup
        let existing = await store.passkeys().filter { $0.relyingPartyID == origin.relyingPartyID }
        return RemotePages.setup(data: [
            "code": code,
            "challenge": Base64URL.encode(challenge),
            "rpId": origin.relyingPartyID,
            "userId": Base64URL.encode(ownerHandle),
            "exclude": existing.map(\.id),
        ])
    }

    private func saveSetup(_ request: HTTPRequest) async -> HTTPResponse {
        let expired = HTTPResponse.json(
            400,
            [
                "error": "invalid_request",
                "error_description":
                    "This setup link expired. Open Honeycrisp's settings and choose Add a passkey again.",
            ])
        guard let object = Self.jsonObject(request.body), let code = object["code"] as? String,
            let setup = setups.removeValue(forKey: code), now() < setup.expiresAt,
            let challenge = setup.challenge
        else { return expired }
        guard let credential = object["credential"] as? [String: Any],
            let clientData = Self.base64Field(credential, "clientDataJSON"),
            let attestation = Self.base64Field(credential, "attestationObject")
        else { return expired }
        do {
            let passkey = try WebAuthn.verifyRegistration(
                clientDataJSON: clientData,
                attestationObject: attestation,
                challenge: challenge,
                origin: origin.origin,
                relyingPartyID: origin.relyingPartyID,
                now: now())
            try await store.addPasskey(passkey)
        } catch {
            return .json(
                400,
                [
                    "error": "invalid_request",
                    "error_description":
                        "Honeycrisp couldn't save that passkey. Open Honeycrisp's settings and try again.",
                ])
        }
        return .json(200, ["ok": true])
    }

    /// The WebAuthn user handle. One owner per Mac and host, so it derives
    /// from the host instead of needing storage.
    private var ownerHandle: Data {
        Data(SHA256.hash(data: Data("honeycrisp-owner:\(origin.relyingPartyID)".utf8)).prefix(16))
    }

    // MARK: - The resource

    private func resource(_ request: HTTPRequest) async -> HTTPResponse {
        if let pageOrigin = request.headers["origin"], pageOrigin != origin.origin {
            return .json(
                403,
                [
                    "error": "forbidden",
                    "error_description": "Honeycrisp refuses requests from web pages on other sites.",
                ])
        }
        let metadata = #"resource_metadata="\#(origin.resourceMetadataURL)""#
        guard let authorization = request.headers["authorization"],
            authorization.lowercased().hasPrefix("bearer ")
        else {
            return .json(
                401,
                ["error": "unauthorized", "error_description": "Sign in to use Honeycrisp."],
                headers: ["WWW-Authenticate": "Bearer " + metadata])
        }
        let token = authorization.dropFirst("bearer ".count).trimmingCharacters(in: .whitespaces)
        guard
            let grant = await store.validate(
                accessToken: token, resource: origin.resource, now: now())
        else {
            return .json(
                401,
                ["error": "invalid_token", "error_description": "That access token is not valid."],
                headers: ["WWW-Authenticate": #"Bearer error="invalid_token", "# + metadata])
        }
        guard request.method == "POST" else {
            return .json(
                405,
                [
                    "error": "method_not_allowed",
                    "error_description": "Honeycrisp answers MCP over POST only.",
                ],
                headers: ["Allow": "POST"])
        }
        return await mcp(request.body, grant.clientName)
    }

    // MARK: - Helpers

    private func prune() {
        let current = now()
        setups = setups.filter { $0.value.expiresAt > current }
        authorizations = authorizations.filter { $0.value.expiresAt > current }
        codes = codes.filter { $0.value.expiresAt > current }
    }

    /// Adds an entry, dropping the one closest to expiry when the table is
    /// full, so nobody can grow ceremony state without bound.
    private static func insert<Value>(
        _ value: Value, for key: String, into table: inout [String: Value],
        expiry: (Value) -> Date
    ) {
        if table.count >= maxPending,
            let oldest = table.min(by: { expiry($0.value) < expiry($1.value) })?.key
        {
            table.removeValue(forKey: oldest)
        }
        table[key] = value
    }

    private func matchesResource(_ value: String) -> Bool {
        var trimmed = value
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed == origin.resource
    }

    static func jsonObject(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func base64Field(_ object: [String: Any], _ key: String) -> Data? {
        (object[key] as? String).flatMap(Base64URL.decode)
    }

    static func cleanName(_ name: String?) -> String {
        let kept = (name ?? "").unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        }
        let trimmed = String(kept)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "An unnamed client" : String(trimmed.prefix(100))
    }

    static func isLoopbackHost(_ host: String) -> Bool {
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        return bare == "localhost" || bare == "127.0.0.1" || bare == "::1"
    }

    static func isAllowedRedirect(_ uri: String) -> Bool {
        guard uri.count <= 2000, let components = URLComponents(string: uri),
            components.fragment == nil, components.user == nil, components.password == nil,
            let host = components.host, !host.isEmpty
        else { return false }
        switch components.scheme?.lowercased() {
        case "https": return true
        case "http": return isLoopbackHost(host)
        default: return false
        }
    }

    /// Exact match, or for loopback http redirects, a match with the port
    /// ignored (RFC 8252 section 7.3), which Claude Code needs.
    static func redirect(_ uri: String, matches registered: [String]) -> Bool {
        if registered.contains(uri) { return true }
        func portless(_ text: String) -> String? {
            guard var components = URLComponents(string: text),
                components.scheme?.lowercased() == "http",
                let host = components.host, isLoopbackHost(host)
            else { return nil }
            components.port = nil
            return components.string
        }
        guard let requested = portless(uri) else { return false }
        return registered.contains { portless($0) == requested }
    }

    /// PKCE challenges and verifiers: 43 to 128 unreserved characters.
    static func isPKCEValue(_ value: String) -> Bool {
        (43...128).contains(value.count)
            && value.unicodeScalars.allSatisfy { unreserved.contains($0) }
    }

    static func pkceChallenge(_ verifier: String) -> String {
        Base64URL.encode(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// Appends parameters to a redirect URI, keeping any query it already
    /// has and escaping everything outside the unreserved set.
    static func redirectURL(_ base: String, _ parameters: [(String, String)]) -> String {
        guard var components = URLComponents(string: base) else { return base }
        let added = parameters.map { name, value in
            let escaped = value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
            return "\(name)=\(escaped)"
        }.joined(separator: "&")
        if let existing = components.percentEncodedQuery, !existing.isEmpty {
            components.percentEncodedQuery = existing + "&" + added
        } else {
            components.percentEncodedQuery = added
        }
        return components.string ?? base
    }
}
