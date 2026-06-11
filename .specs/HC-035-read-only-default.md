# HC-035: Read-only by default

## Why
Honeycrisp can read personal data and, with approval, send mail and messages. For a tool published to the public, the safe default is to read but not write until the user opts in. The default shipped Mail and Reminders at write, which let an assistant draft mail and create reminders out of the box. Read-only by default matches the README and is the more defensible posture; the user enables writes per app in the panel, and outbound sends still require per-request approval on top.

## Scope
- `HoneycrispConfig.default` sets every app to the read level, with write switches off, built consistently through `setLevel(.read, for:)`.
- By default `tools/list` shows the fourteen read tools (the three container-discovery aliases included) and hides the write tools until an app is raised to write.

## Out of scope
- The permission engine, the panel, and the per-request approval for sends, all unchanged.
- The catalog and the action switches themselves.

## Design
The only change is the default's starting levels. Building the default by looping `setLevel(.read, for:)` over every app keeps levels and switches consistent (reads on, writes off) and reuses the deterministic HC-016 semantics rather than hand-listing switches. Raising an app to write in the panel turns its write actions on as before, and `tools/list` follows.

## Test plan
Updated red-first:
- ConfigPersistenceTests: a sparse config now decodes Mail at read, not write.
- ToolGatewayTests: the default listing is the fourteen read tools (no mail_draft, reminders_create, reminders_complete).
- MCPHTTPRouterTests: the default tool count is fourteen.
- CLIParserTests: an `--apps mail` narrow keeps Mail at its default read level; the `--read-only` test starts from a raised-to-write app so it still proves narrowing.
- PermissionEngineTests: the drop-to-read test starts from write so it still proves the drop.

## Acceptance criteria
- `HoneycrispConfig.default.level(for:)` is read for all five apps.
- No write tool is visible on the default config; raising an app to write reveals its write tools.
- The suite is green.
