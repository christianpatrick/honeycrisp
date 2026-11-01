# HC-043: Settings in toolbar tabs

## Why

Settings is one grouped form at a fixed 420 point width, and it grows with every section. With remote access off it is about 906 points tall. Turning remote access on adds the connector URL, the passkey buttons, the passkey count, the remove button, and a row per connected client, which takes it past 1,050 points. A 13-inch MacBook Air has about 920 points under the menu bar and less with the Dock showing, so the bottom of the window (updates, the config folder, the version) is cut off on the laptops most people use.

macOS already has an answer for an app with a handful of settings groups: toolbar tabs in the Settings window, the same pattern Safari, Mail, and Xcode use. SwiftUI draws it from a TabView inside the Settings scene, titles the window after the selected tab, and resizes the window to each tab's content. I compared it with a System Settings style sidebar and with a compact single form that moves remote access into a sheet. Tabs won because they are the most native fit for four groups, they keep every control one click away, and the tallest tab (remote access, running, with a client) is about 550 points.

## Scope

- Settings becomes a TabView with four tabs, each a grouped Form:
  - General (gearshape): launch at login; Updates (check automatically, a "Version 1.3.0" row with Check for Updates Now); the config folder with Show in Finder.
  - Server (server.rack): port, bearer token, endpoint with a copy button, and a footer saying clients on this Mac connect there over loopback only.
  - Remote Access (network): the switch, public URL, tunnel target, status, and connector URL with a copy button. Passkeys and Connected Clients become their own sections. When remote access is off, a footer explains what it does.
  - Activity (clock.arrow.circlepath): retention as a popup of presets instead of a 100-step stepper, and Clear the Activity List, with a footer saying the list stays on this Mac and clearing it cannot be undone.
- Retention presets live in Core (AuditRetention) so the choice list is tested. A retention value from an older config that is not a preset still shows and stays selected.
- Every tab keeps the existing behavior: the same AppModel and UpdaterModel calls, the same submit handling, and the same window configuration (move to the active Space).

## Out of scope

- New settings, config fields, or AppModel behavior. The config file is unchanged.
- The menu bar panel and onboarding.
- Remembering the last selected tab beyond what SwiftUI's Settings scene does by itself.

## Design

- `AuditRetention` in HoneycrispCore/Audit: `presets` is 500, 1,000, 2,000, 5,000, 10,000, and 20,000. `choices(including:)` returns the presets plus the current value when it is not one of them, sorted ascending with no duplicates. `AppModel.updateAuditRetention` keeps its floor of 50.
- SettingsView holds a TabView over four private views (GeneralSettings, ServerSettings, RemoteAccessSettings, ActivitySettings). Each is a `Form` with `.formStyle(.grouped)` and a fixed 500 point width, sized vertically to its content, so the Settings window resizes per tab. Each tab loads its state from the model in onAppear, as the single form did.
- Copy buttons put the string on NSPasteboard. They are icon only (doc.on.doc), so each has an accessibility label and a help tooltip.
- Button titles follow the macOS convention of title case for buttons ("Check for Updates Now", "Show in Finder", "Add a Passkey"). Labels and footers stay sentence case, full sentences, no em-dashes.

## Test plan

Failing test first:

- AuditRetentionTests: the presets are ascending and include the 2,000 default; `choices(including:)` returns the presets unchanged for a preset value; it inserts a custom value (750) in order; it inserts values below and above the range (100, 30,000) at the ends.

The tab layout itself is SwiftUI with no logic of its own, so it is checked by hand: build the app, open Settings, visit each tab with remote access off and on, and confirm the window resizes and every control still works.

## Acceptance criteria

- Settings opens as a toolbar-tabbed window with General, Server, Remote Access, and Activity.
- With remote access running, one passkey, and one connected client, the Remote Access tab fits on a 13-inch MacBook Air screen.
- Every setting from the old form is still present and still saves.
- An existing config with a non-preset retention value keeps it.
- `swift build` and `swift test` pass.
