# HC-037: Hardened runtime entitlements for the Contacts and Calendar prompts

## Why
Onboarding's Allow buttons for Contacts and Calendar do nothing in the released app: no system prompt appears and the rows never flip to Allowed, while Reminders, Mail, and Messages all grant fine. The release build signs with the hardened runtime (HC-032), and the hardened runtime refuses to show a TCC prompt for a protected resource unless the binary carries that resource's entitlement. scripts/Honeycrisp.entitlements grants only Apple Events automation, so macOS denies the Contacts and Calendar requests before any prompt: CNContactStore.requestAccess and EKEventStore.requestFullAccessToEvents simply return false. The other rows never depended on this file. Reminders has no hardened runtime entitlement to demand, and Mail and Messages ride Full Disk Access, which only System Settings grants. Reported by Christian from onboarding a release build.

## Scope
- Add com.apple.security.personal-information.addressbook and com.apple.security.personal-information.calendars to scripts/Honeycrisp.entitlements. The packaging script already applies this file to both the app and the bundled CLI on the Developer ID path, so both binaries pick the keys up.
- Record the rule in AGENTS.md: every TCC service Honeycrisp prompts for through a framework needs its hardened runtime entitlement in this file.

## Out of scope
- Local development builds. They sign without the hardened runtime and were never affected, which is why the bug only shows in the packaged app.
- Full Disk Access and Automation. They are granted through different mechanisms and already work.
- Code changes. PermissionProbes and the onboarding UI behave correctly; the requests were being denied below them.

## Design
The hardened runtime gates access to protected resources by entitlement. Without com.apple.security.personal-information.addressbook the system denies kTCCServiceAddressBook outright, and without com.apple.security.personal-information.calendars it denies kTCCServiceCalendar, in both cases without showing the user anything. The fix is two new keys in the existing entitlements file beside com.apple.security.automation.apple-events. The user still decides at the prompt; the entitlement only permits asking. Info.plist already carries the matching usage strings (NSContactsUsageDescription, NSCalendarsFullAccessUsageDescription), so the packaging script itself does not change.

## Test plan
Packaging configuration, so no unit test, the same scaffolding exemption HC-032 took when it created this file. Verified on a Mac instead:
- codesign -d --entitlements - dist/Honeycrisp.app lists the two new keys after a hardened runtime build.
- On a fresh TCC state (tccutil reset AddressBook app.honeycrisp.Honeycrisp and tccutil reset Calendar app.honeycrisp.Honeycrisp), onboarding's Allow buttons for Contacts and Calendar show the system prompts and the rows flip to Allowed.

## Acceptance criteria
- scripts/Honeycrisp.entitlements carries the addressbook and calendars entitlements beside apple-events.
- A hardened runtime build prompts for Contacts and Calendar from onboarding, and after granting, both rows show Allowed.
- Reminders, Mail, and Messages onboarding behavior is unchanged.
