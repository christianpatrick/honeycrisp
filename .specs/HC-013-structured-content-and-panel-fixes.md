# HC-013: v0.1.1 fixes, structuredContent shape and the collapsed panel

## Why

First real-world session: onboarding granted everything, Claude Desktop connected and called tools, the services did their jobs (the audit log shows allowed reads returning 10 conversations, 5 mail summaries, 14 reminders), and the client still showed every call as failed. Claude Desktop rejects any tool result whose structuredContent is not a JSON object ("the tool result isn't coming back as a valid dictionary"), and our list-returning tools passed their JSON arrays straight through as structuredContent. The MCP spec defines structuredContent as an optional JSON object, so the client is right and we were wrong.

Separately, the menu bar panel rendered only its header, tabs, and footer: a ScrollView inside a MenuBarExtra window collapses to a zero ideal height under the window's unconstrained size proposal, so the whole body vanished.

## Scope

- Gate structuredContent to object-shaped payloads in both response builders (MCPHTTPRouter for the hub, HoneycrispServer.registerHandlers for standalone stdio): an error result or any non-object content sends no structuredContent at all. The content text always carries the full JSON either way.
- Regression tests in the router suite: an array-content call's encoded response has no structuredContent key and stays valid; an object-content call keeps it.
- Give the panel body an explicit height (the design's 470) so MenuBarExtra cannot collapse it.
- Version 0.1.1 in HoneycrispInfo and the packaging script; repackage, relaunch, and verify live through a real MCP client.
- Stable code signing, discovered live: the rebuild orphaned the Full Disk Access grant because ad-hoc signatures change every build and TCC binds FDA to the signature. The packaging script now signs with HONEYCRISP_SIGN_IDENTITY or the first Apple Development certificate (ad-hoc only as a warned fallback), so grants persist across rebuilds. One off-and-on FDA toggle rebinds after this identity change.

## Out of scope

- Wrapping arrays into synthetic objects (the content text already serves the model), and any schema work (outputSchema can come later with typed result schemas).

## Test plan

- Failing first: with the capturing executor scripted to return an array JSON payload, tools/call over the router encodes a response whose result object contains content and isError but no structuredContent key. With the default object payload, structuredContent stays present.
- The panel fix is visual; verification is relaunching the packaged app and seeing the three tabs render (confirmed live in this session).

## Acceptance criteria

- Both regression tests were observed red before the fix and pass after.
- A live tools/call against the running app returns no structuredContent for array results, and a real MCP client (this Claude Code session's honeycrisp connection) successfully reads reminders, messages, and mail through the relaunched app.
- The panel shows Status, Permissions, and Activity content again.
- v0.1.1 tagged.
