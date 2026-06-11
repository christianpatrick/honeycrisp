# HC-030: Automatic update checks preference

## Why
Honeycrisp will ship an in-app updater (HC-034). The user wants the app to check for updates automatically by default, with a Settings checkbox to turn that off and a manual check available either way. The preference is part of the shared config so both the menu bar app (which drives the updater) and a future surface read the same value, and so it persists across launches.

## Scope
- A new `automaticUpdateChecks: Bool` on `HoneycrispConfig`, defaulting to `true`.
- Tolerant decoding: a config written before this field existed loads with the default (checking on), never failing the file.
- It round-trips through disk like every other preference.

## Out of scope
- The updater itself, the Settings checkbox UI, and the manual check (HC-034).
- Any network behavior. This task only adds and persists the preference.

## Design
`HoneycrispConfig` gains one stored `Bool`. It joins the memberwise default, the `CodingKeys`, and the tolerant `init(from:)` with the same `decodeIfPresent ?? fallback` shape every other scalar uses. Default on matches the user's choice; the value drives `SPUUpdater.automaticallyChecksForUpdates` in HC-034.

## Test plan
In `ConfigPersistenceTests`:
- The default has `automaticUpdateChecks == true`.
- Setting it to `false`, saving, and loading returns `false` (round-trip).
- A sparse config without the key loads as `true` (tolerant default).

## Acceptance criteria
- `HoneycrispConfig.default.automaticUpdateChecks` is `true`.
- The preference survives save and load.
- An older config that predates the field decodes to `true` rather than failing.
