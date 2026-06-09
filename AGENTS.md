# AGENTS.md

Working agreements for Honeycrisp. Read this before changing anything. CLAUDE.md points here; this file is the source of truth for process, architecture, and findings. Update it in the same commit as the change that taught you something new.

## What Honeycrisp is

Honeycrisp is a local MCP server for macOS that gives any MCP client fast, private, native access to Mail, Reminders, Messages, and Contacts. It is MIT licensed and it never phones home: no telemetry, no analytics, no crash reporting, loopback networking only. The only record it keeps is a local activity log the user can inspect and clear.

## Architecture (decided 2026-06-09)

- The menu bar app is the hub. Honeycrisp.app (SwiftUI MenuBarExtra, LSUIElement) hosts the MCP server in process over loopback HTTP, default 127.0.0.1:41117. The app owns the TCC identity, so the user grants each macOS permission once to the app instead of once per MCP client.
- The honeycrisp CLI is the bridge. Clients like Claude Desktop run `honeycrisp serve` over stdio. When the app is running, the CLI proxies stdio to the app's HTTP endpoint so every request flows through one supervised process. When the app is not running, the CLI serves standalone over stdio with the same config file, and actions that need notification approval fail closed with an error that tells the user to open the app.
- How we touch Apple apps, in strict order of preference:
  1. A native framework when one exists, for reads and writes both: EventKit for Reminders, the Contacts framework for Contacts.
  2. Read-only database and file access when no framework exists: chat.db SQLite for Messages reads, Mail's Envelope Index SQLite plus .emlx files for Mail reads. Open read-only. We never write to a data store another app owns, ever: no chat.db writes, no Envelope Index writes, no .emlx injection. If Honeycrisp needs an index of its own, it builds one inside its own Application Support folder.
  3. In-process Apple events, only for the few outbound writes that have no framework or store-safe path: composing a Mail draft, sending mail, sending a message. These are raw Apple events sent from Swift under the Automation permission. We never spawn osascript and we never compile or run AppleScript source; both are slow and brittle, and the whole point of Honeycrisp is to not be that.
  4. Driving the app's visible surface as a last resort when even Apple events cannot do something safely: marking a conversation read works by opening the chat through the Messages URL scheme so the Messages daemon updates its own state through its own path.
- Writes whose effect leaves the Mac (send mail, send message, and the Messages draft that sends after approval) always require notification approval even when their switch is on. Local writes (create reminder, complete reminder, create contact, save a Mail draft, mark a conversation read) run without a prompt when their switch is on.
- Targets: HoneycrispCore (library), the honeycrisp CLI (executable), and the Honeycrisp menu bar app (executable). SPM only, no Xcode project. One external dependency: modelcontextprotocol/swift-sdk. The HTTP socket is Network.framework NWListener wrapping the SDK's stateless HTTP transport.
- Every bit of this project is native Swift: the server, the CLI, the app, and the developer tooling. Helper and packaging scripts are Swift files run with the swift command, not shell, Python, or Node. The JSX in the spec is the reference spec, never product code.
- macOS 15 minimum, built with Xcode 26.x and Swift 6.x. In practice verified on macOS 26, which is the machine this project is developed on.
- Bundle IDs: app.honeycrisp.Honeycrisp for the app and app.honeycrisp.cli for the CLI. Do not change them. Changing a bundle ID resets every TCC grant the user has made.
- Config lives at ~/Library/Application Support/honeycrisp/config.json with tolerant decoding so old configs survive new fields. The app and the CLI both read it, and settings apply live without a restart (only a port change restarts the listener). The audit log is audit.jsonl in the same folder.

## Permission model

- Each app has a level: off, read, or write. Write implies read. Each action has a switch. Simple mode sets levels; Advanced mode sets switches.
- Level changes reset switches deterministically: off turns every action off, read turns read actions on and write actions off, and write turns read actions on while leaving write switches as they were.
- The action catalog comes from the catalog spec plus messages mark read, sixteen actions total. After HC-002 the catalog in code is the single source of truth.
- requiresApproval actions are mail.send, messages.send, and messages.draft. These post a notification with Allow once and Don't allow every time they run, are denied on timeout, and land in the audit log as asked or denied. Everything else is auto when its switch is on and blocked when it is off.

## Process rules

1. Spec first. Every task starts as .spec/HC-NNN-slug.md using the template in .spec/README.md. Specs reference their task number HC-NNN. There is no GitHub remote yet, so there are no issue numbers; if a repo appears later, newer specs reference issues instead.
2. TDD, strictly. Write the failing test, run it, and read the failure before writing production code. Then make it pass and run it again. Record the red evidence in the commit body as a "Red:" line. Scaffolding, assets, and docs are exempt; behavior is not.
3. Meaningful tests only. Test observable behavior through public API. Put system frameworks behind protocols and fake them; never sleep and hope. Tests that need real TCC grants are integration tests, gated behind HONEYCRISP_INTEGRATION=1, and run locally on a granted machine rather than in CI.
4. Conventional commits per https://www.conventionalcommits.org/en/v1.0.0/. Commit directly to main. Keep commits small and logical.
5. Keep this file current. A new gotcha, rule, or decision gets appended to the findings log below in the same commit as the change.

## Voice and copy rules

- No em-dashes in anything we author: not in docs, not in code comments, not in commit messages, not in UI strings. Use commas, periods, colons, or the word "and" instead. This rule is non-negotiable.
- The product spec files are never committed. The spec stays local and gitignored at the spec  (see AGENTS.md); the repo carries only the shippable artwork committed, under assets/. Builds and packaging must never depend on the spec existing.
- Full sentences in user-facing copy. Sentence case. No emoji in product copy. The README speaks as Christian in the first person singular.
- Privacy is phrased concretely (on your Mac, nothing uploaded, a local activity list you can clear), never as a buzzword.
- Brand tokens and voice guidance come from the product spec (local, uncommitted); the shippable artwork lives in assets/. The chosen UI direction is System: stock macOS materials, SF Pro, with Honeycrisp red #C5453A as the accent and the four hand-built app icons. The chosen README banner is the letter pair.

## Build and test

- `swift build` and `swift test` from the repo root.
- Integration tests: `HONEYCRISP_INTEGRATION=1 swift test` (first run prompts for TCC grants).
- App bundle: scripts/package-app.swift run with the swift command (arrives with HC-011).

## Findings log

- 2026-06-09 (HC-013, first real session): Three lessons from Claude Desktop actually using Honeycrisp. (1) structuredContent in a tool result must be a JSON object per the MCP spec; Claude Desktop rejects the entire result otherwise ("not a valid dictionary"), even though our list tools were returning good data as arrays. Both response builders now send structuredContent only for object-shaped payloads, regression-tested. (2) A ScrollView inside a MenuBarExtra window collapses to zero ideal height under the window's unconstrained proposal, taking the whole panel body with it; the panel body now has an explicit height. (3) Ad-hoc signatures change every build and macOS binds Full Disk Access to the signature, so every repackage orphaned the FDA grant; the packaging script now signs with HONEYCRISP_SIGN_IDENTITY or the first Apple Development certificate, falling back to ad-hoc with a warning. After any signing identity change, FDA needs one off-and-on toggle in System Settings to rebind.

- 2026-06-09: Christian's rule, learned the hard way: the product spec files are never committed. The original HC-001 import was purged from the entire history with filter-branch (the repo was local-only with no remote, and a pre-rewrite bundle was saved), the spec  is now gitignored, and packaging sources artwork from assets/ only.
- 2026-06-09 (HC-012): Live verification through the packaged app on this Mac: /health, initialize, gated tools/list, a denied mail_send writing the real audit entry, and the CLI auto-bridging stdio through the running app with exact client attribution all verified. Two behaviors to know: the prior build's config.json carried its port (8765) through tolerant decoding, which is intended, so the hub serves there until the user changes it in Settings; and an allowed call that touches an ungranted framework suspends inside the system permission prompt until the user answers, which is correct first-use behavior but means a smoke test against an ungranted app hangs rather than failing.

- 2026-06-09: The development harness running this work can neither show TCC prompts (CNContactStore.requestAccess auto-denies with CNError 100 while the status stays notDetermined) nor read FDA-protected stores (chat.db and ~/Library/Mail are "authorization denied" even unsandboxed). Gated integration tests therefore run from a TCC-capable host: launch them from Terminal.app, which can present prompts and can be granted Full Disk Access in System Settings. The authoritative end-to-end verification is through the packaged Honeycrisp.app (HC-012), which is the product's real TCC identity and the grant-once story we ship.

- 2026-06-09: Christian locked the language constraint: every bit of the project is native Swift, including developer tooling. No shell, Python, or Node scripts.
- 2026-06-09: Christian locked the app-access constraint: maximum performance, zero osascript, and nothing ever writes to a data store another app owns. The hierarchy in the architecture section (framework, then read-only store access, then in-process Apple events for approved outbound writes only, then URL-scheme driving) is the binding interpretation.
- 2026-06-09: Repo reset and rebuilt spec-first from the product spec preserved in the spec. Knowledge carried over from the previous build that must not be relearned the hard way: (a) the MCP swift-sdk's default initialize handler rejects a second initialize on a shared stateless server, so re-register a tolerant initialize handler after server.start(), because start() registers default handlers and clobbers earlier overrides; (b) macOS file systems are case insensitive, so the CLI binary inside Honeycrisp.app/Contents/MacOS must be named honeycrisp-cli, because a binary named honeycrisp silently overwrites the app executable Honeycrisp and the bundle then launches the stdio CLI which exits on EOF; (c) load app resources via Bundle.main from Contents/Resources, copied in by the packaging script, not via SPM Bundle.module, which breaks under codesign inside an app bundle; (d) marking an iMessage conversation read stays SIP safe by driving Messages.app through its URL scheme, foregrounding it, confirming with a fresh snapshot, and restoring focus, 1:1 chats only, never by writing chat.db, because read state belongs to the Messages daemon and direct database writes do not sync.
