# GH-16: Remote access through your own tunnel

## Why

Issue #16: remote MCP clients can't connect. Custom connectors in claude.ai, Claude Desktop, Cowork, and the Claude iPhone app all reach a server from Anthropic's cloud, never from my device, so 127.0.0.1 is invisible to them. Claude's connector docs also rule out the bearer token Honeycrisp has today: a custom connector speaks OAuth or nothing.

I run Tailscale on my Mac mini, and Tailscale Funnel can already put a local port on a public https address. What is missing is everything that makes that safe: an OAuth server inside Honeycrisp, a way for me to prove it is me when a client asks to connect, and a local port that refuses to be the thing a tunnel points at by mistake. Every Honeycrisp user should get this, so it lives in the app. Nobody runs a server for it, me included: each user brings their own tunnel.

## Scope

- A second listener, the remote port (default 41118, loopback only like the first), that runs only when remote access is on and a public URL is set. A tunnel the user runs points at it.
- OAuth 2.1 built into the app on that port: protected resource metadata (RFC 9728), authorization server metadata (RFC 8414), dynamic client registration (RFC 7591), the authorization code grant with S256 PKCE, refresh token rotation, and the iss parameter on every authorization response (RFC 9207).
- Passkey sign-in on the consent page, with the passkey registered through a one-time setup link from Settings.
- /mcp on the remote port answers only access tokens Honeycrisp issued for that exact resource, and hands everything else a 401 that points at the metadata.
- The local port refuses requests that look like they came through a tunnel or a rebound DNS name.
- Settings: the remote access switch, the public URL, the passkey setup link, and the list of connected remote clients with a disconnect button for each.
- README, SECURITY.md, and AGENTS.md describe the new threat model, with Tailscale Funnel as the documented example.

## Out of scope

- Send approvals that reach my phone. Remote sends keep the Mac notification in this task and time out as denied when nobody answers it. That is the next task.
- Client ID Metadata Documents. Supporting them means Honeycrisp fetching URLs a stranger hands it, and Claude falls back to dynamic registration when the metadata doesn't advertise them.
- Redirect URIs other than https and loopback http, so custom URL schemes some desktop clients use wait for a request.
- OAuth scopes. Every remote client gets the permissions the panel sets for every client, the same as local clients.
- A relay Honeycrisp runs, iCloud web services, and the website copy (the letter makes no claim this changes).
- Recording sign-ins in the activity list. Its rows are tool calls tied to an app; connections show in Settings instead.

## Design

### Addresses

- Config gains `remoteAccessEnabled` (default false), `remotePort` (default 41118), and `publicURL` (default none), decoded tolerantly like every other field.
- RemoteOrigin parses the public URL. It accepts https only, lowercases the host, drops a trailing `/` or `/mcp` so pasting the connector URL works, and refuses query strings, fragments, user info, and any other path. From it come the issuer (the origin), the resource (origin + `/mcp`, the exact URL I paste into Claude), and the passkey relying party ID (the host).

### Two listeners

- LoopbackHTTPServer gains a general start that takes a request handler, and the existing local start becomes a handler on top of it, so the local behavior stays as it is.
- Both listeners stay bound to 127.0.0.1. Tailscale Funnel, Cloudflare Tunnel, and ngrok all forward to a local port, so remote requests arrive on loopback too. That is why the two ports have to differ: on a single port, the source address can't tell my Mac from the internet.
- The local port answers 403 when the Host header names anything but 127.0.0.1, localhost, or ::1, or when the request carries Forwarded or X-Forwarded-For. Tunnels set at least one of those, so pointing a tunnel at the wrong port fails closed instead of exposing an unauthenticated server. The Host check also stops a web page from reaching the local port through DNS rebinding.
- Both listeners drop a connection that hasn't delivered its whole request within 30 seconds, so a slow client on the public side can't hold sockets open forever. Handling time doesn't count, because a send can wait two minutes on an approval.
- The request reader accepts chunked bodies as well as Content-Length ones, because a tunnel may forward either.

### OAuth

- `/.well-known/oauth-protected-resource` and `/.well-known/oauth-protected-resource/mcp` return the resource and the issuer as its one authorization server.
- `/.well-known/oauth-authorization-server` returns the issuer, the authorize, token, and registration endpoints, code as the only response type, authorization_code and refresh_token as the grant types, S256 as the only challenge method, none as the only token endpoint auth method, and `authorization_response_iss_parameter_supported: true`.
- `/register` takes JSON. Redirect URIs must be https with a host, or http on localhost, 127.0.0.1, or [::1], with no fragment, at most ten of them. Client names are trimmed of control characters and capped at 100 characters. Every client is public (token_endpoint_auth_method none, whatever it asked for). Claude registers a new client on every fresh connection, so the store keeps at most 50 and drops the oldest ones that never got a grant.
- `/authorize` checks the client and the redirect URI first, and shows an error page instead of redirecting when either is wrong, so a bad request can't bounce through Honeycrisp to an attacker's site. Loopback redirects match with the port ignored, which Claude Code needs. After that it requires response_type code, an S256 code challenge, and a resource that matches when one is sent; those failures redirect back with invalid_request.
- The consent page names the client, shows the host the browser returns to, warns when that host is loopback, and says the client gets the same access every client has and that sends still need approval on the Mac. Allow runs the passkey ceremony; Don't allow returns access_denied. Pending requests live in memory for 10 minutes.
- An approved request becomes a single-use authorization code that lives for 2 minutes, bound to the client, the redirect URI, the code challenge, and the resource.
- `/token` takes form-encoded bodies, which is what Claude sends. The code grant checks the client, the exact redirect URI, the PKCE verifier, the resource, the expiry, and that the code is unused. The refresh grant checks the client and the expiry, then rotates: the old refresh token stops working in the same response that issues the new one. Failures use invalid_grant, invalid_client, invalid_request, or unsupported_grant_type, with `Cache-Control: no-store` on every token response.
- Tokens are 32 random bytes from the system generator, base64url encoded, with an `hc_at_` or `hc_rt_` prefix. The store keeps only their SHA-256 hashes. Access tokens live 1 hour. Refresh tokens live 30 days from their last use, so a connection I use stays connected and one I abandon expires.
- `/mcp` (any method) without a valid access token gets 401 with `WWW-Authenticate: Bearer resource_metadata="<origin>/.well-known/oauth-protected-resource"`. A token issued for another resource is invalid, so changing the public URL disconnects everything. A request whose Origin header isn't the public origin gets 403. A valid POST goes to the same MCP router the local port uses, attributed to the client name from registration; other methods get 405.

### Passkeys

- Settings asks the running remote server for a setup code (16 random bytes, single use, 10 minutes) and opens or copies `<origin>/setup?code=...`. The page has to load through the tunnel, because a passkey belongs to the host the browser sees.
- The setup page creates a passkey for relying party ID = the public host, ES256 only, user verification required, attestation none, and existing passkeys excluded. Honeycrisp verifies the client data (type, challenge, origin), the authenticator data (relying party hash, user present, user verified, attested credential), and the COSE key (EC2, ES256, P-256), then saves the credential ID, public key, sign count, and relying party ID.
- The consent page asks for an assertion with every saved passkey for the current host allowed and user verification required. Honeycrisp verifies the client data, the authenticator data, and the P-256 signature over the authenticator data plus the client data hash. When either sign count is nonzero, the new one has to be higher, which catches a cloned authenticator; synced passkeys always report zero.
- A small CBOR decoder reads the attestation object and the COSE key. It handles definite lengths only, bounds every length against the input, and stops nesting at 16 levels.

### Pages

- Each page is self-contained HTML with inline CSS and one inline script, served with a per-response CSP nonce, `default-src 'none'`, `frame-ancestors 'none'`, `form-action 'none'`, `X-Frame-Options: DENY`, and `Cache-Control: no-store`. Every value interpolated into HTML is escaped, and the page data rides a JSON script block with `<` escaped, because the client name comes from a stranger.

### Storage

- RemoteAccessStore is an actor that keeps passkeys, registered clients, and grants in remote-access.json in the support folder, written atomically with 0600 permissions. Nothing in it can be replayed: token hashes, public keys, and client metadata. The settings list and the server read the same store, so a disconnect in Settings kills the tokens at once.
- Ceremony state (setup codes, pending authorizations, authorization codes) stays in memory, so restarting the app cancels any flow in progress.

### App and permissions

- AppModel starts the remote listener after the local one when remote access is on and the public URL parses, and restarts only the remote listener when a remote setting changes. A remote start failure shows in Settings and never stops the local server.
- No catalog change, no new action, and the approval set stays mail.send and messages.send.

## Test plan

Failing tests first:

- HTTPMessageTests: query and form decoding with `+` and percent escapes, duplicate parameters refused, chunked bodies decoded whole, an incomplete chunked body waiting for more, and malformed chunk sizes refused.
- RemoteOriginTests: https origins with and without a trailing `/` or `/mcp` parse to the same issuer, resource, and relying party ID; uppercase hosts lowercase; ports survive; http, query strings, fragments, user info, other paths, and garbage parse to nil.
- CBORTests: unsigned and negative integers at every length width, byte and text strings, arrays, maps with integer and text keys, nesting, and the byte count consumed; truncated input, indefinite lengths, and nesting past 16 throw.
- WebAuthnTests with a software authenticator built from a CryptoKit P-256 key and a test CBOR encoder: a good registration yields the credential; a wrong type, challenge, origin, or relying party, missing user verification, missing attested data, or a non-ES256 key throws. A good assertion verifies and returns the new count; a bad signature, an unknown credential, and a count that goes backwards throw.
- RemoteAccessServerTests, driving the handler directly with a fake MCP closure and a controllable clock: both metadata documents; 401 with the resource metadata pointer on /mcp; registration rules and the 50 client cap; authorize errors that render a page versus those that redirect; the escaped client name and the CSP header on the consent page; the loopback port rule; the full flow from passkey setup through consent, token exchange, an /mcp call that reaches the fake router with the client name, refresh rotation, and the old refresh and access tokens failing; PKCE mismatch, code reuse, an expired code, and an expired access token; deny returning access_denied with state and iss; a foreign Origin getting 403; a revoked grant getting 401; and setup links that expire and work once.
- RemoteAccessStoreTests: state survives a reload, the file is 0600, and revoking a grant invalidates its tokens.
- LoopbackHTTPServerTests: the local port answers 403 to a request carrying X-Forwarded-For, and LocalRequestGuard accepts the loopback hosts with and without ports and refuses other hosts and forwarded requests.
- ConfigPersistenceTests: the new fields default to off, 41118, and none, and an old config without them still loads.
- AppModelTests: turning remote access on with a public URL starts a second listener whose /mcp answers 401 with the metadata pointer, and turning it off stops it while the local port keeps answering.

## Acceptance criteria

- `swift build` and `swift test` pass, with red evidence recorded in the commit bodies.
- With remote access off, nothing listens on the remote port and the local port behaves as before for local clients.
- With Tailscale Funnel pointed at the remote port, I add `https://<my mac>.<my tailnet>.ts.net/mcp` as a custom connector in claude.ai, sign in with a passkey from my iPhone, and call a read tool. Verified live.
- Disconnecting the client in Settings makes its next call fail with 401.
- Pointing Funnel at the local port by mistake gets 403 instead of an open server.
- README, SECURITY.md, and AGENTS.md describe remote access and its threat model in the same change.
