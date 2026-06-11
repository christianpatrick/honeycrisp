# AGENTS.md

Working agreements for Honeycrisp. Read this before changing anything. CLAUDE.md points here; this file is the source of truth for process and architecture. Update it in the same commit as the change that taught you something new.

## What Honeycrisp is

Honeycrisp is a local MCP server for macOS that gives any MCP client fast, private, native access to Mail, Reminders, Calendar, Messages, and Contacts. It is MIT licensed and it never phones home: no telemetry, no analytics, no crash reporting, loopback networking only. The only record it keeps is a local activity log the user can inspect and clear.

## Architecture

- The menu bar app is the hub. Honeycrisp.app (SwiftUI MenuBarExtra, LSUIElement) hosts the MCP server in process over loopback HTTP, default 127.0.0.1:41117. The app owns the TCC identity, so the user grants each macOS permission once to the app instead of once per MCP client.
- The honeycrisp CLI is the bridge. Clients like Claude Desktop run `honeycrisp serve` over stdio. When the app is running, the CLI proxies stdio to the app's HTTP endpoint so every request flows through one supervised process. When the app is not running, the CLI serves standalone over stdio with the same config file, and actions that need notification approval fail closed with an error that tells the user to open the app.
- How we touch Apple apps, in strict order of preference:
  1. A native framework when one exists, for reads and writes both: EventKit for Reminders and Calendar, the Contacts framework for Contacts.
  2. Read-only database and file access when no framework exists: chat.db SQLite for Messages reads, Mail's Envelope Index SQLite plus .emlx files for Mail reads. Open read-only. We never write to a data store another app owns, ever: no chat.db writes, no Envelope Index writes, no .emlx injection. If Honeycrisp needs an index of its own, it builds one inside its own Application Support folder.
  3. In-process Apple events, only for the few outbound writes that have no framework or store-safe path: composing a Mail draft, sending mail, sending a message. These are raw Apple events sent from Swift under the Automation permission. We never spawn osascript and we never compile or run AppleScript source; both are slow and brittle, and the whole point of Honeycrisp is to not be that.
  4. Driving the app's visible surface as a last resort when even Apple events cannot do something safely: marking a conversation read works by opening the chat through the Messages URL scheme so the Messages daemon updates its own state through its own path.
- Writes whose effect leaves the Mac (send mail and send message) always require notification approval even when their switch is on. Local writes (create reminder, complete reminder, create contact, create calendar event, save a Mail draft, mark a conversation read, mark mail read) run without a prompt when their switch is on. There is no Messages draft: iMessage has no draft concept, so a tool named draft that actually sent would lie about its effect (removed in HC-025).
- Targets: HoneycrispCore (library), the honeycrisp CLI (executable), and the Honeycrisp menu bar app (executable). SPM only, no Xcode project. One external dependency: modelcontextprotocol/swift-sdk. The HTTP socket is Network.framework NWListener wrapping the SDK's stateless HTTP transport.
- Every bit of this project is native Swift: the server, the CLI, the app, and the developer tooling. Helper and packaging scripts are Swift files run with the swift command, not shell, Python, or Node.
- macOS 15 minimum, built with Xcode 26.x and Swift 6.x. In practice verified on macOS 26, which is the machine this project is developed on.
- Bundle IDs: app.honeycrisp.Honeycrisp for the app and app.honeycrisp.cli for the CLI. Do not change them. Changing a bundle ID resets every TCC grant the user has made.
- Config lives at ~/Library/Application Support/honeycrisp/config.json with tolerant decoding so old configs survive new fields. The app and the CLI both read it, and settings apply live without a restart (only a port change restarts the listener). The audit log is audit.jsonl in the same folder.

## Permission model

- Each app has a level: off, read, or write. Write implies read. Each action has a switch. Simple mode sets levels; Advanced mode sets switches.
- Level changes reset switches deterministically (HC-016 semantics): off turns every action off, read turns read actions on and write actions off, and write turns every action on. Simple mode is the blunt instrument and Advanced is the curation surface; outbound sends always keep their per-request approval, so write never means silent sends.
- The action catalog is twenty actions across five apps. The typed catalog in code (ActionCatalog) is the single source of truth.
- Not every tool is a catalog row. Container discovery tools (mail_mailboxes, reminders_lists, calendar_calendars) are registry aliases: each rides the permission switch of an existing read action (mail.search, reminders.list, calendar.list) but executes and audits its own operation. A new alias needs no catalog, permission, or UI change, only a registry entry.
- requiresApproval actions are mail.send and messages.send. These post a notification with Allow once and Don't allow every time they run, are denied on timeout, and land in the audit log as asked or denied. Everything else is auto when its switch is on and blocked when it is off.

## Process rules

1. Spec first. Every task starts as .specs/HC-NNN-slug.md using the template in .specs/README.md. Specs reference their task number HC-NNN.
2. TDD, strictly. Write the failing test, run it, and read the failure before writing production code. Then make it pass and run it again. Record the red evidence in the commit body as a "Red:" line. Scaffolding, assets, and docs are exempt; behavior is not.
3. Meaningful tests only. Test observable behavior through public API. Put system frameworks behind protocols and fake them; never sleep and hope. Tests that need real TCC grants are integration tests, gated behind HONEYCRISP_INTEGRATION=1, and run locally on a granted machine rather than in CI.
4. Conventional commits per https://www.conventionalcommits.org/en/v1.0.0/. Commit directly to main. Keep commits small and logical.
5. Keep this file current. A new rule or decision gets recorded here in the same commit as the change that established it.

## Voice and copy rules

- No em-dashes in anything we author: not in docs, not in code comments, not in commit messages, not in UI strings. Use commas, periods, colons, or the word "and" instead. This rule is non-negotiable.
- Full sentences in user-facing copy. Sentence case. No emoji in product copy. The README speaks as Christian in the first person singular.
- Privacy is phrased concretely (on your Mac, nothing uploaded, a local activity list you can clear), never as a buzzword.
- The shippable artwork lives in assets/. The UI direction is System: stock macOS materials, SF Pro, with Honeycrisp red #C5453A as the accent and the hand-built app icons. The wordmark is Honeycrisp in Sora semibold at -0.03em tracking with a brand-red period.

## Build and test

- `swift build` and `swift test` from the repo root.
- Integration tests: `HONEYCRISP_INTEGRATION=1 swift test` (first run prompts for TCC grants).
- App bundle: scripts/package-app.swift run with the swift command.
