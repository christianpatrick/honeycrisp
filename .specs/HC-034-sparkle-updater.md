# HC-034: Sparkle in-app updater

## Why
Honeycrisp ships outside the App Store, so it needs to update itself. The user wants it to check automatically by default, with a Settings checkbox to turn that off and a manual check available either way. HC-030 added the persisted preference; this task wires the actual updater to it and to the release feed (HC-033).

## Scope
- Sparkle as a dependency of the menu bar app target only; Core, the CLI, and the tests stay Sparkle-free.
- `UpdaterModel`, a small `@MainActor` wrapper over `SPUStandardUpdaterController`: it starts the updater, seeds `automaticallyChecksForUpdates` from the config, exposes a manual `checkForUpdates()`, and a `setAutomaticChecks(_:)` the Settings toggle calls.
- A Settings "Updates" section: a "Check for updates automatically" toggle bound to `HoneycrispConfig.automaticUpdateChecks` (persisted through `AppModel`, default on) and a "Check for Updates Now" button.
- Packaging: bundle `Sparkle.framework` into `Contents/Frameworks`, add the `@executable_path/../Frameworks` rpath before signing, sign Sparkle's nested code deepest-first on the Developer ID path, and stamp `SUFeedURL`, `SUPublicEDKey`, and `SUEnableAutomaticChecks` into Info.plist.
- Honest privacy copy in AGENTS.md and the README: the update check is the one outbound request, sends no personal data, and is switchable.

## Out of scope
- The release pipeline that produces the appcast and the signed zip (HC-033).
- The Sparkle private key (a CI secret); only the public key ships in Info.plist.

## Design
The config is the source of truth. `AppModel.updateAutomaticUpdateChecks` persists the preference; the Settings toggle calls that and pushes the same value into `UpdaterModel`, so Sparkle and the config never disagree. Sparkle reads `SUFeedURL` and `SUPublicEDKey` from the bundle at startup. Because the bundle is assembled by a script rather than Xcode, the framework is copied in and the rpath is added before the final codesign; on the Developer ID path the nested XPC services, helper app, and framework are signed before the executables so notarization accepts the bundle without `--deep`.

## Test plan
The updater and its UI are AppKit/SwiftUI integration, exempt from unit tests. The new testable seam, `AppModel.updateAutomaticUpdateChecks`, is covered in `AppModelTests` (default on, persists across instances). Verified by building, packaging, and launching: `Sparkle.framework` lands in `Contents/Frameworks`, the rpath resolves, `codesign --verify --deep` passes, and the app runs with the updater initialized (health responds, no dyld or Sparkle errors). The download-and-install flow proves out against the first real notarized release.

## Acceptance criteria
- The menu bar app links Sparkle; Core, the CLI, and the tests do not.
- Settings shows the auto-check toggle (default on) and a manual check; toggling persists and reaches the updater.
- A packaged build bundles and signs `Sparkle.framework`, stamps the Sparkle Info.plist keys, and launches cleanly.
- The suite stays green.
