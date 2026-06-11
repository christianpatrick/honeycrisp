# HC-004: MCP server core with tool catalog and gating

- Task number: HC-004 (no GitHub issue yet)
- Status: done
- Date: 2026-06-09

## Why

This is the seam where the permission engine, the audit log, and the eventual app services meet the Model Context Protocol. Every request a client makes flows through one gateway that lists only what the user allowed, refuses what they did not with a sentence a person can read, asks when approval is required, and writes the audit entry either way.

## Scope

- ToolRegistry: one MCP tool per catalog action, named app_action (mail_search, messages_mark_read), with descriptions, JSON schemas, read-only annotations, and a per-tool approval prompt builder used for notification copy.
- ToolGateway: the testable heart. listTools() filters by visibleActions; callTool(name:arguments:) runs the decision, the optional approval, the executor, and the audit write, and returns content plus an isError flag.
- Protocol seams: ToolExecutor (implemented by fakes here and by the app services in HC-006 through HC-009) and ApprovalRequesting (implemented by the broker in HC-005).
- HoneycrispServer: the thin adapter that registers the gateway on the SDK Server (initialize, tools/list, tools/call) and can run over stdio. Compile-verified here, live-verified from HC-010 on.
- Dependency: modelcontextprotocol/swift-sdk, resolved at 0.12.1.

## Out of scope

- Real app services, the notification UI, HTTP transport, the CLI, client connection tracking (the gateway takes a clientName closure; HC-010 feeds it).

## Design

- Tool names are app_action with the catalog ids verbatim, so messages mark read is messages_mark_read.
- callTool flow:
  1. Unknown tool name: isError result saying the tool is unknown. No audit entry; permission denials are worth recording, junk names are not.
  2. decision == denied: isError result with a human sentence built from the catalog label, in the voice of the mock (for example "Send mail is turned off for Mail, so the request was blocked before anything left your Mac."). Audit outcome denied, with rows naming the permission that blocked it.
  3. decision == needsApproval and no broker is wired (standalone CLI): fail closed with a sentence telling the user to open the menu bar app. Audit outcome denied.
  4. decision == needsApproval and the broker approves: run, audit outcome asked, detail rows record the approval.
  5. decision == needsApproval and the broker denies (or times out, which the broker reports as a denial): isError "You did not allow this, so nothing left your Mac." Audit outcome denied.
  6. decision == allowed: run, audit outcome allowed.
  7. The executor throwing: isError with the failure message. The audit entry stays outcome allowed (permissions did permit it) with a summary that says it failed; the three outcomes stay exactly the design's three badges.
- The gateway measures execution time and appends a Duration row to the audit detail, matching the mock's rows.
- The executor returns a ToolOutcome: the JSON content for the model plus the audit sentence, summary, and rows. Services own how their results are described.
- Approval prompts are argument-aware per tool ("Claude Desktop wants to send a mail to alex@studio.com."), built by the registry so HC-005 and the notification UI get the same copy.
- Client attribution comes from a clientName closure captured at initialize. With one stdio session per client this is exact; the shared HTTP server's best effort is defined in HC-010.
- Tool results also carry structuredContent with the same JSON for clients that read it.

## Test plan

ToolGatewayTests with a recording fake executor, a scripted fake broker, a temp AuditStore, and config variations:

- listTools on the default config surfaces exactly the eleven visible actions (mail search, read, draft; all four reminders; messages recent, search; contacts lookup, fields) and hides the rest.
- Enabling messages.send makes messages_send appear.
- Unknown tool: isError, executor untouched, audit stays empty.
- mail_send on the default config: isError mentioning it is turned off, executor untouched, audit records denied for mail.send with the client name.
- mail_search: executor receives app, action, and arguments; the result carries the executor's JSON; audit records allowed with the executor's sentence and a Duration row.
- messages_send enabled with no broker: fail closed, audit denied, message points at the menu bar app.
- messages_send enabled, broker approves: executor runs, audit outcome asked, and the broker received a prompt containing the recipient.
- messages_send enabled, broker denies: executor untouched, audit denied, message says nothing left the Mac.
- Executor throws: isError with the message, audit outcome allowed with a failing summary.
- A hand-built config with messages level read and send switch on: denied with the read-only sentence.

## Acceptance criteria

- All tests above exist, were observed red before implementation (recorded in the commit body), and pass.
- swift build compiles HoneycrispServer against MCP 0.12.1 including the stdio entrypoint.
- The registry covers all sixteen actions with schemas and descriptions.
