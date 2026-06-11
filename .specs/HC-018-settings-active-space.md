# HC-018: Settings opens on the current Space

## Why

macOS pins a window to the Space it last lived on, so opening Settings from the panel switched the user to that Space instead of presenting the window where they are. A menu bar utility's windows should come to the user.

## Scope

- A WindowConfigurator (NSViewRepresentable) that grabs the hosting NSWindow when the view lands in one and applies configuration idempotently; SettingsView uses it to insert the moveToActiveSpace collection behavior.
- Version 0.1.6, repackage, relaunch.

## Test plan

View-layer only, TDD-exempt per AGENTS.md process rule 2. Verification: open Settings, switch Space, open Settings again, and the window appears on the current Space.

## Acceptance criteria

- Opening Settings never switches Spaces; the window appears wherever the user is.
- swift test stays green; v0.1.6 packaged, running, tagged.
