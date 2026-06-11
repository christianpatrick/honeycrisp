# HC-010: Loopback HTTP transport, CLI bridge, client tracking

## Why

The app-as-hub architecture becomes real here: one supervised process serving MCP over loopback HTTP, a CLI that bridges stdio clients into it so the README's Claude Desktop snippet works unchanged, and the connected-clients registry the panel header counts ("2 clients connected").

## Scope

- MCPHTTPRouter: a socket-free, fully testable JSON-RPC router over the ToolGateway handling initialize (with version negotiation against the SDK's supported set), notifications (202, no body), ping, tools/list, and tools/call. Repeated initialize is simply fine here because we own the handler, which retires the SDK clobbering gotcha for the HTTP path entirely.
- Per-request client attribution: the bridge stamps X-Honeycrisp-Client on every POST once it has seen the client's initialize, the router prefers that header, and otherwise falls back to the last initialized client. ToolGateway.callTool gains an optional client override so attribution is per request, not per process.
- ClientRegistry: an actor recording who initialized and when, feeding both the panel list and the attribution fallback.
- LoopbackHTTPServer: NWListener bound to 127.0.0.1 (port 0 supported for tests), minimal HTTP/1.1 parsing, POST /mcp to the router, GET /health with version, optional bearer token enforcement on /mcp (401 otherwise), Connection: close per request.
- MCPProxy: the stdio-to-HTTP bridge core as a pure-ish function over an async line sequence, a post closure, and a write closure, so it unit-tests without processes. It captures the client name from initialize, forwards every line, writes responses, drops empty notification replies, and synthesizes a JSON-RPC -32603 error with the original id when the hub stops answering.
- The honeycrisp CLI executable: `serve` (bridge to the app when its /health answers, standalone stdio otherwise), `serve --port N` (standalone loopback HTTP), `--apps` and `--read-only` flags that narrow the standalone config (bridged mode follows the app's central settings by design), and `version`. Argument parsing is a pure function with tests; no new dependencies.

## Out of scope

- The menu bar app itself (HC-011), notifications, TLS (loopback only), and HTTP keep-alive.

## Design

- The router reuses the SDK's public Codable types (Initialize.Parameters and Result, CallTool.Parameters, ListTools.Result, Tool) so wire shapes stay spec-correct while routing is ours. Unknown methods get -32601, unparseable bodies get -32700 with a null id, invalid params get -32602.
- Version negotiation: a requested version in Version.supported is echoed, anything else gets Version.latest.
- Standalone stdio keeps using the full SDK Server (HoneycrispServer.runStdio), so protocol conformance on that path is the SDK's.
- Standalone CLI and the app may both append to audit.jsonl; line-oriented appends interleave safely enough for v0.1 and the trim rewrite race is accepted and noted.
- The CLI reloads config from disk per request through its configProvider, so settings changes apply live to standalone serving too.

## Test plan

MCPHTTPRouterTests with the recording fake executor: initialize negotiates and records the client; repeated initialize succeeds; tools/list reflects config; tools/call attributes the header client in the audit entry and falls back to the last initialized client without it; notifications return empty; ping returns an empty result; unknown method and parse errors map to the right JSON-RPC codes.

LoopbackHTTPServerTests over real loopback sockets on an ephemeral port: /health answers with the version; /mcp without the configured bearer is 401 and with it initialize round-trips; a second initialize also succeeds end to end.

MCPProxyTests: forwards lines and writes responses; captures the client name from initialize and stamps later posts; writes nothing for empty notification replies; synthesizes the -32603 error with the original id when post throws.

CLIParserTests: serve defaults, --port, --apps, --read-only, version, and unknown flags; applyServeFlags narrows a config (--read-only drops write levels to read and forces write switches off; --apps turns unlisted apps off).

## Acceptance criteria

- All tests above exist, were observed red before implementation (recorded in the commit body), and pass.
- swift build produces a honeycrisp executable with serve and version.
- swift test stays green, including the real-socket suite.
