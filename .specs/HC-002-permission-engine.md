# HC-002: Permission engine and config model

## Why

Every tool call in Honeycrisp is gated by what the user allowed, and the menu bar panel, the onboarding flow, and the audit log all hang off the same model. The product spec defines the apps, actions, kinds, labels, and default switches, and how Simple mode level changes reset switches. This task turns that into the typed domain core everything else builds on.

## Scope

- The action catalog: four apps, sixteen actions, with labels, kinds, defaults, and approval flags.
- The permission evaluation that turns (app, action, config) into allowed, needsApproval, or denied with a reason.
- The mutations the UI needs: set a level (Simple mode), toggle an action (Advanced mode).
- The config struct with tolerant decoding, normalization against the catalog, and atomic save and load at ~/Library/Application Support/honeycrisp/config.json.

## Out of scope

- The MCP wiring that consumes decisions (HC-004), the approval broker (HC-005), the audit log (HC-003), and any UI.

## Design

### Catalog

From the product spec, plus one carried-over action (messages mark read). Kind write implies the action mutates something; requiresApproval marks the writes whose effect leaves the Mac, and those three post a notification every time per the AGENTS.md permission model.

| App | Action id | Label | Kind | Default | Approval |
| --- | --- | --- | --- | --- | --- |
| mail | search | Search mailboxes | read | on | no |
| mail | read | Read a thread | read | on | no |
| mail | draft | Draft a reply | write | on | no |
| mail | send | Send mail | write | off | yes |
| reminders | list | List reminders | read | on | no |
| reminders | due | Check what is due today | read | on | no |
| reminders | create | Create a reminder | write | on | no |
| reminders | complete | Mark as done | write | on | no |
| messages | recent | Read recent messages | read | on | no |
| messages | search | Search conversations | read | on | no |
| messages | draft | Draft a reply | write | off | yes |
| messages | send | Send a message | write | off | yes |
| messages | mark_read | Mark a conversation read | write | off | no |
| contacts | lookup | Look up a contact | read | on | no |
| contacts | fields | Read phone & email | read | on | no |
| contacts | create | Add a contact | write | off | no |

App display data (name and blurb) lives in the catalog too so the panel and onboarding reuse it.

Notes:
- messages.draft is "compose, then send after the user approves the notification", which is why it carries the approval flag. It is the designed way to reply in Messages.
- messages.mark_read can emit a read receipt to the other person, so it ships default off; turning it on is a deliberate choice. It does not require per-use approval.
- Default levels: mail write, reminders write, messages read, contacts read.

### Evaluation

Levels are stored (off, read, write), exactly as the mock stores perm, and they gate before switches:

1. Unknown app or action: denied(unknownAction).
2. Level off: denied(appOff).
3. Write action while level is read: denied(readOnlyApp).
4. Switch off: denied(actionOff).
5. requiresApproval: needsApproval.
6. Otherwise: allowed.

Rule 3 matters because a hand-edited config can say level read with a write switch on; the engine must not trust switches alone.

### Mutations

- setLevel follows the spec exactly: off turns every switch off; read turns read switches on and write switches off; write turns read switches on and leaves write switches as they were.
- setAction toggles one switch, and turning a switch on auto-raises the level so the switch is actually effective (read action: off becomes read; write action: off or read becomes write). Without this, Advanced mode could show an enabled switch that rule 2 or 3 silently overrides, which would be a lying UI. Turning a switch off never lowers the level.

### Listing

visibleActions(for:) returns the actions that are not denied (allowed or needsApproval). HC-004 uses it to gate tools/list so clients never see tools they cannot call.

### Config

HoneycrispConfig is Codable, Equatable, Sendable, and carries: levels, switches, port (default 41117), defaultLimit (20), defaultRemindersList (nil), auditMaxEntries (2000), bearerToken (nil), loggingEnabled (false), onboardingCompleted (false).

- Tolerant decoding: every missing key falls back to the default, so configs written by older builds survive newer code.
- Normalization: after load, any catalog action missing from switches gets its default, switch keys not in the catalog are dropped, and missing app levels get their defaults.
- load(from:) returns the default config when the file is missing or unreadable; it never throws and never deletes the existing file.
- save(to:) writes atomically and creates the directory chain. Encoding is pretty-printed with sorted keys so the file diffs cleanly.
- The default path is ~/Library/Application Support/honeycrisp/config.json. Tests always pass an explicit temp URL.

## Test plan

Failing first, in Tests/HoneycrispCoreTests, using Swift Testing.

ActionCatalogTests:
- Sixteen actions with per-app counts 4, 4, 5, 3.
- Exactly three approval actions: mail.send, messages.send, messages.draft.
- Spot checks: labels, kinds, and defaults for mail.send, messages.mark_read, reminders.complete.

PermissionEngineTests:
- Default config: mail.search allowed, mail.send denied(actionOff), messages.recent allowed, messages.draft denied(readOnlyApp), reminders.create allowed, contacts.create denied(readOnlyApp). The last two looked like actionOff at first, but the evaluation order is normative: levels gate before switches, so a write action under a read level reports readOnlyApp, which is also the truthful message for a Simple mode user. mail.send reports actionOff because mail's default level is write.
- Enabling mail.send yields needsApproval, never allowed.
- setLevel(.off, mail) denies mail.search with appOff.
- setLevel(.read, mail) forces write switches off while search stays on.
- setLevel(.write, messages) turns reads on and leaves draft and send off.
- setAction(send, on, messages) auto-raises messages to write and the decision becomes needsApproval.
- A hand-built config with level read and the send switch on is denied with readOnlyApp.
- Unknown action id is denied with unknownAction.
- visibleActions for the default config: mail lists search, read, draft; messages lists recent, search.

ConfigPersistenceTests:
- Round trip: save then load equals the saved value.
- Missing file loads the default.
- Corrupt JSON loads the default and leaves the file in place.
- A JSON object containing only {"port": 5} decodes with every other field at its default.
- A config missing messages.mark_read gains it with its default after normalization, and an unknown switch key is dropped.
- save creates intermediate directories and the result is valid JSON.

## Acceptance criteria

- All tests above exist, were observed red before implementation (recorded in the commit body), and pass.
- The catalog table in this spec matches ActionCatalog in code one to one.
- swift test passes with zero skipped tests on this machine.
