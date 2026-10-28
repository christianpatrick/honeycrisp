import Foundation
import Testing
import HoneycrispCore

/// Stands in for the MCP router behind the remote port.
private actor MCPRecorder {
    private(set) var clients: [String] = []
    private(set) var bodies: [Data] = []

    func record(_ body: Data, client: String) {
        bodies.append(body)
        clients.append(client)
    }
}

@Suite("Remote access server")
struct RemoteAccessServerTests {
    private let origin = RemoteOrigin(publicURL: "https://mac.example.ts.net")!
    private let claudeCallback = "https://claude.ai/api/mcp/auth_callback"
    private let verifier = "a-code-verifier-that-is-long-enough-for-pkce-0123456789"

    private struct Harness {
        let server: RemoteAccessServer
        let store: RemoteAccessStore
        let clock: TestClock
        let recorder: MCPRecorder
    }

    private func makeHarness() -> Harness {
        let clock = TestClock()
        let store = RemoteAccessStore(fileURL: tempStoreURL("remote-access.json"))
        let recorder = MCPRecorder()
        let server = RemoteAccessServer(
            origin: origin,
            store: store,
            mcp: { body, client in
                await recorder.record(body, client: client)
                return HTTPResponse(
                    status: 200, headers: ["Content-Type": "application/json"],
                    body: Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8))
            },
            now: { clock.now }
        )
        return Harness(server: server, store: store, clock: clock, recorder: recorder)
    }

    // MARK: - Flow helpers

    private func setUpPasskey(_ harness: Harness, _ authenticator: SoftwareAuthenticator) async throws {
        let link = await harness.server.makeSetupLink()
        let code = try #require(redirectParameters(link.absoluteString)["code"])
        let page = await harness.server.handle(getRequest("/setup?code=\(code)"))
        #expect(page.status == 200)
        let data = pageData(page)
        let challenge = try #require(Base64URL.decode(data["challenge"] as? String ?? ""))
        #expect(data["rpId"] as? String == "mac.example.ts.net")
        let registration = authenticator.register(
            challenge: challenge, origin: origin.origin, relyingPartyID: origin.relyingPartyID)
        let saved = await harness.server.handle(
            jsonRequest(
                "/setup",
                [
                    "code": code,
                    "credential": [
                        "id": authenticator.credentialIDString,
                        "clientDataJSON": Base64URL.encode(registration.clientDataJSON),
                        "attestationObject": Base64URL.encode(registration.attestationObject),
                    ],
                ]))
        #expect(saved.status == 200)
    }

    private func registerClient(
        _ harness: Harness, name: String = "Claude", redirect: String? = nil
    ) async throws -> String {
        let response = await harness.server.handle(
            jsonRequest(
                "/register",
                ["client_name": name, "redirect_uris": [redirect ?? claudeCallback]]))
        #expect(response.status == 201)
        return try #require(jsonObject(response)["client_id"] as? String)
    }

    private func authorizeTarget(
        clientID: String, redirect: String? = nil, extra: [(String, String)] = []
    ) -> String {
        let fields: [(String, String)] =
            [
                ("response_type", "code"),
                ("client_id", clientID),
                ("redirect_uri", redirect ?? claudeCallback),
                ("code_challenge", pkceChallenge(verifier)),
                ("code_challenge_method", "S256"),
                ("state", "xyz"),
                ("resource", origin.resource),
            ] + extra
        return "/authorize?" + queryString(fields)
    }

    private func approve(
        _ harness: Harness, _ authenticator: SoftwareAuthenticator, page: HTTPResponse
    ) async throws -> HTTPResponse {
        let data = pageData(page)
        let request = try #require(data["request"] as? String)
        let challenge = try #require(Base64URL.decode(data["challenge"] as? String ?? ""))
        let assertion = authenticator.assert(
            challenge: challenge, origin: origin.origin, relyingPartyID: origin.relyingPartyID)
        return await harness.server.handle(
            jsonRequest(
                "/authorize",
                [
                    "request": request,
                    "approve": true,
                    "credential": [
                        "id": authenticator.credentialIDString,
                        "clientDataJSON": Base64URL.encode(assertion.clientDataJSON),
                        "authenticatorData": Base64URL.encode(assertion.authenticatorData),
                        "signature": Base64URL.encode(assertion.signature),
                    ],
                ]))
    }

    private func authorizationCode(
        _ harness: Harness, _ authenticator: SoftwareAuthenticator, clientID: String,
        redirect: String? = nil
    ) async throws -> String {
        let page = await harness.server.handle(
            getRequest(authorizeTarget(clientID: clientID, redirect: redirect)))
        #expect(page.status == 200)
        let approved = try await approve(harness, authenticator, page: page)
        #expect(approved.status == 200)
        let redirectURL = try #require(jsonObject(approved)["redirect"] as? String)
        return try #require(redirectParameters(redirectURL)["code"])
    }

    private func exchange(
        _ harness: Harness, code: String, clientID: String, verifier: String? = nil,
        redirect: String? = nil
    ) async -> HTTPResponse {
        await harness.server.handle(
            formRequest(
                "/token",
                [
                    ("grant_type", "authorization_code"),
                    ("code", code),
                    ("redirect_uri", redirect ?? claudeCallback),
                    ("client_id", clientID),
                    ("code_verifier", verifier ?? self.verifier),
                    ("resource", origin.resource),
                ]))
    }

    private func connect(_ harness: Harness) async throws -> (
        clientID: String, access: String, refresh: String
    ) {
        let authenticator = SoftwareAuthenticator()
        try await setUpPasskey(harness, authenticator)
        let clientID = try await registerClient(harness)
        let code = try await authorizationCode(harness, authenticator, clientID: clientID)
        let tokens = await exchange(harness, code: code, clientID: clientID)
        #expect(tokens.status == 200)
        let object = jsonObject(tokens)
        return (
            clientID,
            try #require(object["access_token"] as? String),
            try #require(object["refresh_token"] as? String)
        )
    }

    private func mcpCall(
        _ harness: Harness, token: String?, extraHeaders: [String: String] = [:]
    ) async -> HTTPResponse {
        var headers = extraHeaders
        headers["content-type"] = "application/json"
        if let token { headers["authorization"] = "Bearer \(token)" }
        return await harness.server.handle(
            HTTPRequest(
                method: "POST", target: "/mcp", headers: headers,
                body: Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8)))
    }

    // MARK: - Metadata

    @Test("protected resource metadata names the resource and its one issuer")
    func resourceMetadata() async {
        let harness = makeHarness()
        for path in [
            "/.well-known/oauth-protected-resource", "/.well-known/oauth-protected-resource/mcp",
        ] {
            let response = await harness.server.handle(getRequest(path))
            #expect(response.status == 200)
            let object = jsonObject(response)
            #expect(object["resource"] as? String == "https://mac.example.ts.net/mcp")
            #expect(object["authorization_servers"] as? [String] == ["https://mac.example.ts.net"])
        }
    }

    @Test("authorization server metadata advertises exactly what Honeycrisp supports")
    func serverMetadata() async {
        let harness = makeHarness()
        let response = await harness.server.handle(
            getRequest("/.well-known/oauth-authorization-server"))
        #expect(response.status == 200)
        let object = jsonObject(response)
        #expect(object["issuer"] as? String == "https://mac.example.ts.net")
        #expect(object["authorization_endpoint"] as? String == "https://mac.example.ts.net/authorize")
        #expect(object["token_endpoint"] as? String == "https://mac.example.ts.net/token")
        #expect(object["registration_endpoint"] as? String == "https://mac.example.ts.net/register")
        #expect(object["response_types_supported"] as? [String] == ["code"])
        #expect(
            object["grant_types_supported"] as? [String] == ["authorization_code", "refresh_token"])
        #expect(object["code_challenge_methods_supported"] as? [String] == ["S256"])
        #expect(object["token_endpoint_auth_methods_supported"] as? [String] == ["none"])
        #expect(object["authorization_response_iss_parameter_supported"] as? Bool == true)
        #expect(object["client_id_metadata_document_supported"] == nil)
    }

    @Test("an unknown path is 404")
    func notFound() async {
        let harness = makeHarness()
        #expect(await harness.server.handle(getRequest("/health")).status == 404)
    }

    // MARK: - The resource

    @Test("mcp without a token gets 401 pointing at the metadata")
    func unauthenticated() async {
        let harness = makeHarness()
        let response = await mcpCall(harness, token: nil)
        #expect(response.status == 401)
        #expect(
            response.headers["WWW-Authenticate"]
                == #"Bearer resource_metadata="https://mac.example.ts.net/.well-known/oauth-protected-resource""#
        )
        #expect(await harness.recorder.bodies.isEmpty)
    }

    @Test("mcp with a token Honeycrisp never issued gets 401 invalid_token")
    func invalidToken() async {
        let harness = makeHarness()
        let response = await mcpCall(harness, token: "hc_at_forged")
        #expect(response.status == 401)
        #expect(response.headers["WWW-Authenticate"]?.contains(#"error="invalid_token""#) == true)
        #expect(await harness.recorder.bodies.isEmpty)
    }

    @Test("a GET on mcp still asks for a token first")
    func getWithoutToken() async {
        let harness = makeHarness()
        let response = await harness.server.handle(getRequest("/mcp"))
        #expect(response.status == 401)
    }

    // MARK: - Registration

    @Test("registration returns a public client")
    func registration() async throws {
        let harness = makeHarness()
        let response = await harness.server.handle(
            jsonRequest(
                "/register",
                [
                    "client_name": "Claude", "redirect_uris": [claudeCallback],
                    "token_endpoint_auth_method": "client_secret_post",
                ]))
        #expect(response.status == 201)
        let object = jsonObject(response)
        #expect((object["client_id"] as? String)?.isEmpty == false)
        #expect(object["client_secret"] == nil)
        #expect(object["token_endpoint_auth_method"] as? String == "none")
        #expect(object["redirect_uris"] as? [String] == [claudeCallback])
        #expect(object["client_name"] as? String == "Claude")
        #expect(response.headers["Cache-Control"] == "no-store")
    }

    @Test("registration accepts https and loopback redirects only")
    func registrationRedirects() async {
        let harness = makeHarness()
        for good in [
            "http://localhost/callback", "http://127.0.0.1:3118/callback", "http://[::1]/cb",
            "https://vscode.dev/redirect",
        ] {
            let response = await harness.server.handle(
                jsonRequest("/register", ["redirect_uris": [good]]))
            #expect(response.status == 201, "\(good)")
        }
        for bad in [
            "http://evil.example/cb", "https://claude.ai/cb#frag", "cursor://callback", "not a url",
            "https:///nohost",
        ] {
            let response = await harness.server.handle(
                jsonRequest("/register", ["redirect_uris": [bad]]))
            #expect(response.status == 400, "\(bad)")
            #expect(jsonObject(response)["error"] as? String == "invalid_redirect_uri")
        }
        let none = await harness.server.handle(jsonRequest("/register", ["client_name": "x"]))
        #expect(none.status == 400)
        let tooMany = await harness.server.handle(
            jsonRequest(
                "/register",
                ["redirect_uris": (0..<11).map { "https://a.example/cb\($0)" }]))
        #expect(tooMany.status == 400)
    }

    @Test("registration trims control characters and caps the name")
    func registrationName() async {
        let harness = makeHarness()
        let response = await harness.server.handle(
            jsonRequest(
                "/register",
                [
                    "client_name": "Cla\u{0}ude\n" + String(repeating: "x", count: 200),
                    "redirect_uris": [claudeCallback],
                ]))
        let name = jsonObject(response)["client_name"] as? String ?? ""
        #expect(name.hasPrefix("Claude"))
        #expect(name.count == 100)
    }

    // MARK: - Authorize

    @Test("an unknown client or redirect shows an error page and never redirects")
    func authorizeRefusesToRedirect() async throws {
        let harness = makeHarness()
        let clientID = try await registerClient(harness)
        let unknown = await harness.server.handle(getRequest(authorizeTarget(clientID: "nope")))
        #expect(unknown.status == 400)
        #expect(unknown.headers["Content-Type"]?.hasPrefix("text/html") == true)
        let wrongRedirect = await harness.server.handle(
            getRequest(authorizeTarget(clientID: clientID, redirect: "https://evil.example/cb")))
        #expect(wrongRedirect.status == 400)
        #expect(wrongRedirect.headers["Location"] == nil)
        #expect(pageData(wrongRedirect)["request"] == nil)
    }

    @Test("a missing PKCE challenge, a wrong method, or a foreign resource redirect with invalid_request")
    func authorizeInvalidRequest() async throws {
        let harness = makeHarness()
        let authenticator = SoftwareAuthenticator()
        try await setUpPasskey(harness, authenticator)
        let clientID = try await registerClient(harness)
        let targets = [
            "/authorize?"
                + queryString([
                    ("response_type", "code"), ("client_id", clientID),
                    ("redirect_uri", claudeCallback), ("state", "xyz"),
                ]),
            authorizeTarget(clientID: clientID).replacingOccurrences(
                of: "code_challenge_method=S256", with: "code_challenge_method=plain"),
            authorizeTarget(clientID: clientID).replacingOccurrences(
                of: "response_type=code", with: "response_type=token"),
            "/authorize?"
                + queryString([
                    ("response_type", "code"), ("client_id", clientID),
                    ("redirect_uri", claudeCallback), ("code_challenge", pkceChallenge(verifier)),
                    ("code_challenge_method", "S256"), ("state", "xyz"),
                    ("resource", "https://other.example/mcp"),
                ]),
        ]
        for target in targets {
            let response = await harness.server.handle(getRequest(target))
            #expect(response.status == 302, "\(target)")
            let location = response.headers["Location"] ?? ""
            #expect(location.hasPrefix(claudeCallback), "\(target)")
            let parameters = redirectParameters(location)
            #expect(
                parameters["error"] == "invalid_request" || parameters["error"] == "unsupported_response_type"
                    || parameters["error"] == "invalid_target", "\(target)")
            #expect(parameters["state"] == "xyz")
            #expect(parameters["iss"] == "https://mac.example.ts.net")
        }
    }

    @Test("the consent page escapes the client name and locks itself down")
    func consentPage() async throws {
        let harness = makeHarness()
        let authenticator = SoftwareAuthenticator()
        try await setUpPasskey(harness, authenticator)
        let clientID = try await registerClient(harness, name: "<script>alert(1)</script>")
        let page = await harness.server.handle(getRequest(authorizeTarget(clientID: clientID)))
        #expect(page.status == 200)
        let html = text(page)
        #expect(!html.contains("<script>alert(1)</script>"))
        #expect(html.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
        #expect(html.contains("claude.ai"))
        let csp = page.headers["Content-Security-Policy"] ?? ""
        #expect(csp.contains("default-src 'none'"))
        #expect(csp.contains("frame-ancestors 'none'"))
        #expect(csp.contains("script-src 'nonce-"))
        #expect(page.headers["X-Frame-Options"] == "DENY")
        #expect(page.headers["Cache-Control"] == "no-store")
        #expect(pageData(page)["allow"] as? [String] == [authenticator.credentialIDString])
    }

    @Test("the consent page says when to add a passkey first")
    func consentWithoutPasskey() async throws {
        let harness = makeHarness()
        let clientID = try await registerClient(harness)
        let page = await harness.server.handle(getRequest(authorizeTarget(clientID: clientID)))
        #expect(page.status == 200)
        #expect(text(page).contains("passkey"))
        #expect(pageData(page)["request"] == nil)
    }

    @Test("loopback redirects match with the port ignored and get a warning")
    func loopbackRedirect() async throws {
        let harness = makeHarness()
        let authenticator = SoftwareAuthenticator()
        try await setUpPasskey(harness, authenticator)
        let clientID = try await registerClient(harness, redirect: "http://localhost/callback")
        let page = await harness.server.handle(
            getRequest(authorizeTarget(clientID: clientID, redirect: "http://localhost:3118/callback")))
        #expect(page.status == 200)
        #expect(text(page).contains("this device"))
        let otherPath = await harness.server.handle(
            getRequest(authorizeTarget(clientID: clientID, redirect: "http://localhost:3118/other")))
        #expect(otherPath.status == 400)
    }

    @Test("Don't allow returns access_denied with the state and issuer")
    func deny() async throws {
        let harness = makeHarness()
        let authenticator = SoftwareAuthenticator()
        try await setUpPasskey(harness, authenticator)
        let clientID = try await registerClient(harness)
        let page = await harness.server.handle(getRequest(authorizeTarget(clientID: clientID)))
        let request = try #require(pageData(page)["request"] as? String)
        let denied = await harness.server.handle(
            jsonRequest("/authorize", ["request": request, "approve": false]))
        #expect(denied.status == 200)
        let parameters = redirectParameters(jsonObject(denied)["redirect"] as? String ?? "")
        #expect(parameters["error"] == "access_denied")
        #expect(parameters["state"] == "xyz")
        #expect(parameters["iss"] == "https://mac.example.ts.net")
        #expect(parameters["code"] == nil)
    }

    @Test("approving with a stranger's passkey fails and issues no code")
    func strangerPasskey() async throws {
        let harness = makeHarness()
        try await setUpPasskey(harness, SoftwareAuthenticator())
        let clientID = try await registerClient(harness)
        let page = await harness.server.handle(getRequest(authorizeTarget(clientID: clientID)))
        let response = try await approve(harness, SoftwareAuthenticator(), page: page)
        #expect(response.status == 400)
        #expect(jsonObject(response)["redirect"] == nil)
    }

    // MARK: - The whole flow

    @Test("passkey setup, consent, token exchange, an mcp call, and refresh all work end to end")
    func fullFlow() async throws {
        let harness = makeHarness()
        let authenticator = SoftwareAuthenticator()
        try await setUpPasskey(harness, authenticator)
        let clientID = try await registerClient(harness, name: "Claude")

        let page = await harness.server.handle(getRequest(authorizeTarget(clientID: clientID)))
        let approved = try await approve(harness, authenticator, page: page)
        let redirect = try #require(jsonObject(approved)["redirect"] as? String)
        #expect(redirect.hasPrefix(claudeCallback + "?"))
        let parameters = redirectParameters(redirect)
        #expect(parameters["state"] == "xyz")
        #expect(parameters["iss"] == "https://mac.example.ts.net")
        let code = try #require(parameters["code"])

        let tokens = await exchange(harness, code: code, clientID: clientID)
        #expect(tokens.status == 200)
        #expect(tokens.headers["Cache-Control"] == "no-store")
        let object = jsonObject(tokens)
        #expect(object["token_type"] as? String == "Bearer")
        #expect(object["expires_in"] as? Int == 3600)
        let access = try #require(object["access_token"] as? String)
        let refresh = try #require(object["refresh_token"] as? String)

        let call = await mcpCall(harness, token: access)
        #expect(call.status == 200)
        #expect(await harness.recorder.clients == ["Claude"])

        let refreshed = await harness.server.handle(
            formRequest(
                "/token",
                [("grant_type", "refresh_token"), ("refresh_token", refresh), ("client_id", clientID)]))
        #expect(refreshed.status == 200)
        let renewed = jsonObject(refreshed)
        let newAccess = try #require(renewed["access_token"] as? String)
        #expect(renewed["refresh_token"] as? String != refresh)

        let replay = await harness.server.handle(
            formRequest(
                "/token",
                [("grant_type", "refresh_token"), ("refresh_token", refresh), ("client_id", clientID)]))
        #expect(replay.status == 400)
        #expect(jsonObject(replay)["error"] as? String == "invalid_grant")
        #expect(await mcpCall(harness, token: access).status == 401)
        #expect(await mcpCall(harness, token: newAccess).status == 200)
    }

    @Test("a wrong PKCE verifier, a reused code, and an expired code are invalid_grant")
    func codeRules() async throws {
        let harness = makeHarness()
        let authenticator = SoftwareAuthenticator()
        try await setUpPasskey(harness, authenticator)
        let clientID = try await registerClient(harness)

        let first = try await authorizationCode(harness, authenticator, clientID: clientID)
        let wrong = await exchange(
            harness, code: first, clientID: clientID,
            verifier: "a-different-verifier-that-is-also-long-enough-0123456789")
        #expect(wrong.status == 400)
        #expect(jsonObject(wrong)["error"] as? String == "invalid_grant")

        let second = try await authorizationCode(harness, authenticator, clientID: clientID)
        #expect(await exchange(harness, code: second, clientID: clientID).status == 200)
        let reused = await exchange(harness, code: second, clientID: clientID)
        #expect(jsonObject(reused)["error"] as? String == "invalid_grant")

        let third = try await authorizationCode(harness, authenticator, clientID: clientID)
        harness.clock.advance(121)
        let expired = await exchange(harness, code: third, clientID: clientID)
        #expect(jsonObject(expired)["error"] as? String == "invalid_grant")
    }

    @Test("a code only works with the redirect it was issued for")
    func codeRedirect() async throws {
        let harness = makeHarness()
        let authenticator = SoftwareAuthenticator()
        try await setUpPasskey(harness, authenticator)
        let clientID = try await registerClient(harness)
        let code = try await authorizationCode(harness, authenticator, clientID: clientID)
        let response = await exchange(
            harness, code: code, clientID: clientID, redirect: "https://claude.ai/other")
        #expect(jsonObject(response)["error"] as? String == "invalid_grant")
    }

    @Test("the token endpoint names unknown grants and missing fields")
    func tokenErrors() async {
        let harness = makeHarness()
        let unsupported = await harness.server.handle(
            formRequest("/token", [("grant_type", "client_credentials")]))
        #expect(jsonObject(unsupported)["error"] as? String == "unsupported_grant_type")
        let missing = await harness.server.handle(
            formRequest("/token", [("grant_type", "authorization_code")]))
        #expect(jsonObject(missing)["error"] as? String == "invalid_request")
    }

    @Test("an access token expires after an hour")
    func accessExpiry() async throws {
        let harness = makeHarness()
        let connection = try await connect(harness)
        harness.clock.advance(3601)
        #expect(await mcpCall(harness, token: connection.access).status == 401)
    }

    @Test("a foreign Origin header gets 403 even with a good token")
    func foreignOrigin() async throws {
        let harness = makeHarness()
        let connection = try await connect(harness)
        let response = await mcpCall(
            harness, token: connection.access, extraHeaders: ["origin": "https://evil.example"])
        #expect(response.status == 403)
        let same = await mcpCall(
            harness, token: connection.access, extraHeaders: ["origin": "https://mac.example.ts.net"])
        #expect(same.status == 200)
    }

    @Test("a revoked grant gets 401 on its next call")
    func revoked() async throws {
        let harness = makeHarness()
        let connection = try await connect(harness)
        let grant = try #require(await harness.store.grants().first)
        await harness.store.revokeGrant(id: grant.id)
        #expect(await mcpCall(harness, token: connection.access).status == 401)
    }

    @Test("an authorized GET on mcp is 405")
    func getWithToken() async throws {
        let harness = makeHarness()
        let connection = try await connect(harness)
        let response = await harness.server.handle(
            getRequest("/mcp", headers: ["authorization": "Bearer \(connection.access)"]))
        #expect(response.status == 405)
    }

    // MARK: - Setup links

    @Test("a setup link works once and expires after ten minutes")
    func setupLinks() async throws {
        let harness = makeHarness()
        let authenticator = SoftwareAuthenticator()
        try await setUpPasskey(harness, authenticator)
        #expect(await harness.store.passkeys().map(\.id) == [authenticator.credentialIDString])

        let bogus = await harness.server.handle(getRequest("/setup?code=bogus"))
        #expect(bogus.status == 400)
        #expect(pageData(bogus)["challenge"] == nil)

        let link = await harness.server.makeSetupLink()
        #expect(link.absoluteString.hasPrefix("https://mac.example.ts.net/setup?code="))
        let code = try #require(redirectParameters(link.absoluteString)["code"])
        harness.clock.advance(601)
        let expired = await harness.server.handle(getRequest("/setup?code=\(code)"))
        #expect(expired.status == 400)
    }

    @Test("a used setup code can't add a second passkey")
    func setupCodeSingleUse() async throws {
        let harness = makeHarness()
        let link = await harness.server.makeSetupLink()
        let code = try #require(redirectParameters(link.absoluteString)["code"])
        let page = await harness.server.handle(getRequest("/setup?code=\(code)"))
        let challenge = try #require(Base64URL.decode(pageData(page)["challenge"] as? String ?? ""))

        func save(_ authenticator: SoftwareAuthenticator) async -> HTTPResponse {
            let registration = authenticator.register(
                challenge: challenge, origin: origin.origin, relyingPartyID: origin.relyingPartyID)
            return await harness.server.handle(
                jsonRequest(
                    "/setup",
                    [
                        "code": code,
                        "credential": [
                            "id": authenticator.credentialIDString,
                            "clientDataJSON": Base64URL.encode(registration.clientDataJSON),
                            "attestationObject": Base64URL.encode(registration.attestationObject),
                        ],
                    ]))
        }
        #expect(await save(SoftwareAuthenticator()).status == 200)
        #expect(await save(SoftwareAuthenticator()).status == 400)
        #expect(await harness.store.passkeys().count == 1)
    }
}
