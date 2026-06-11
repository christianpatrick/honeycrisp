# HC-032: Notarized Developer ID packaging

## Why
A downloadable Mac app is blocked by Gatekeeper unless it is Developer ID signed, built with the hardened runtime, and notarized by Apple. The release pipeline (HC-033) needs the packaging script to produce that artifact, while a local build on the developer's own machine must keep working without an Apple Developer account or notarization credentials.

## Scope
- An entitlements file, `scripts/Honeycrisp.entitlements`, declaring `com.apple.security.automation.apple-events` (Honeycrisp drives Mail and Messages; the hardened runtime requires the entitlement, and the user still grants the TCC automation prompt).
- The packaging script signs the Developer ID path with hardened runtime (`--options runtime`), a secure timestamp, and the entitlements, signing the nested CLI first and the bundle last (no `--deep`, which notarization rejects).
- When notarytool credentials are present (`NOTARYTOOL_KEY_ID`, `NOTARYTOOL_ISSUER_ID`, `NOTARYTOOL_KEY_PATH`), the script zips with ditto, submits with `notarytool --wait`, and staples the ticket.

## Out of scope
- The workflow that imports the cert and supplies the credentials (HC-033).
- Sparkle's nested code signing, which HC-034 folds into the same inner-then-outer signing.

## Design
The signing identity selection is unchanged: `HONEYCRISP_SIGN_IDENTITY` (the workflow sets this to the Developer ID), else the first Apple Development cert, else ad-hoc. The new behavior keys off whether the identity is a Developer ID. If it is, the distribution path runs (hardened runtime, timestamp, entitlements, then notarize and staple if credentials exist). Otherwise the existing simple, FDA-stable local sign runs untouched, so day-to-day development is unaffected.

## Test plan
Build infrastructure, so no unit test (AGENTS.md exempts scaffolding). Verified by running `swift scripts/package-app.swift` locally: it signs with Apple Development, prints that notarization was skipped, and produces a working bundle, proving the script parses and the local path is unchanged.

## Acceptance criteria
- A local `swift scripts/package-app.swift` still produces `dist/Honeycrisp.app` and skips notarization cleanly.
- With a Developer ID identity and notarytool credentials, the script signs hardened, notarizes, and staples.
- The entitlements file grants only Apple Events automation.
