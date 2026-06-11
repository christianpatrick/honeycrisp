# HC-011: Menu bar app

- Task number: HC-011 (no GitHub issue yet)
- Status: done
- Date: 2026-06-09

## Why

The product deliverable is the System-direction control surface: a menu bar panel with Status, Permissions, and Activity, first-run onboarding, and the approval notification. The app is also the architecture: it hosts the hub server in process and owns the TCC identity, which is the grant-once story.

## Scope

- HoneycrispMenuBar executable target: SwiftUI MenuBarExtra (window style) with the brand glyph as a template image, plus an onboarding window on first run and a Settings scene. LSUIElement comes from the packaged Info.plist.
- AppModel (@MainActor, @Observable): owns the live config (persisting every mutation), the audit store, the approval broker, the client registry, and the loopback server lifecycle (start, pause, port from config, ephemeral port supported for tests). It exposes the panel's data: server state, clients, glance counts, audit entries, pending approvals.
- Panel UI matching the panel spec in the System direction: header (icon, title, clients-connected line, Running and Paused pill), segmented Status, Permissions, Activity tabs, the two glance tiles, connected clients group, per-app access summary with Manage, Simple mode tri-toggles, Advanced mode expandable per-action switches with read and write badges, expandable audit rows with the three outcome badges and the detail grid, Open full history, and the footer (Settings, version, Quit).
- Onboarding matching the onboarding spec: Welcome, Allow access (four rows wired to the real grants: Contacts and Reminders prompt in place; Mail and Messages need Full Disk Access so their button opens the System Settings pane and the row re-probes), What it can do (tri-toggles writing the real config), Connect (client pick, real snippet with the bundled CLI path, live connection wait against the registry), Done.
- Approval notifications: UNUserNotificationCenter category with Allow once and Don't allow actions resolving the broker; the panel also lists pending approvals as a fallback surface (notifications require the packaged bundle, and a user can miss a banner).
- Settings: launch at login (SMAppService), port, optional bearer token, audit retention, clear activity, open the config folder.
- scripts/package-app.swift: a Swift script (run with the swift command) that builds release, assembles Honeycrisp.app with the locked bundle id app.honeycrisp.Honeycrisp, usage strings, LSUIElement, the bundled CLI named honeycrisp-cli (the case-insensitive filesystem gotcha from AGENTS.md), brand resources from the spec, an icns rendered from the brand icon, and an ad-hoc codesign.

## Out of scope

- Notarization, Sparkle updates, Liquid Glass icon compilation (flat render is the fallback per the prior build's finding), and live end-to-end verification with real grants (HC-012).

## Design

- The model is the only stateful object; views render it. Config mutations go through model methods that persist to disk immediately, so the CLI and the server's configProvider see changes live.
- The broker's onRequest hops to the MainActor, appends to pendingApprovals, and asks the presenter (UNUserNotificationCenter in production, a fake in tests) to post. Resolution from either the notification action or the panel resolves the broker and removes the entry.
- Theme constants come from the design tokens (Honeycrisp red #C5453A as the accent, the system green running dot, gold for read badges) while materials stay stock, which is exactly the System direction.
- The glyph and app icons load from Contents/Resources via Bundle.main in the packaged app (the SPM Bundle.module trap from AGENTS.md), with an SF Symbol fallback for bare swift run development.

## Test plan

AppModelTests, failing first, on the main actor with a temp config, a temp audit store, the capturing executor, and a recording fake presenter:

- start() on port 0 reaches running with a real port and /health answers; pause() stops the listener and /health stops answering; the state line copy matches the design ("2 clients connected", "Server paused").
- setLevel and toggleAction persist to the temp config file immediately and the running server's tools/list reflects the change live.
- The approval round trip over the real loopback: enabling messages_send, posting tools/call, the presenter receives the prompt, pendingApprovals shows it, resolveApproval(true) lets the call finish with the executor's payload, and the audit entry lands as asked. Declining resolves denied.
- completeOnboarding persists the flag so the second launch skips onboarding.
- refresh() pulls counts, entries, and clients after activity.

## Acceptance criteria

- All model tests above exist, were observed red before implementation (recorded in the commit body), and pass.
- swift build compiles the HoneycrispMenuBar target; swift test stays green.
- scripts/package-app.swift produces a signed Honeycrisp.app with the CLI bundled as honeycrisp-cli, correct Info.plist keys, resources, and icon.
