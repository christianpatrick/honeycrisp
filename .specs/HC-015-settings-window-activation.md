# HC-015: Bring the Settings window to the front

## Why

Honeycrisp is an accessory app (LSUIElement, no Dock icon), and macOS does not activate accessory apps just because one of their windows appeared. Opening Settings from the panel therefore presented the window behind every other app.

## Scope

- Replace the footer's SettingsLink with a button that activates the app, opens Settings through the openSettings environment action, and then re-asserts activation and key ordering a beat later for reliability under cooperative activation.
- Version 0.1.3, repackage, relaunch.

## Test plan

View-layer only, TDD-exempt per AGENTS.md process rule 2. Verification: suite green, and opening Settings from the running panel lands the window frontmost.

## Acceptance criteria

- Settings opens in front of other apps from the menu bar panel.
- swift test stays green; v0.1.3 packaged, running, tagged.
