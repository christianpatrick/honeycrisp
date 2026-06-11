# HC-031: Tag-derived version

## Why
The version lived as two hardcoded strings, one in `HoneycrispInfo` and one in the packaging script, kept in sync by hand. The release pipeline (HC-033) computes the next version from conventional commits and tags it, so the git tag has to be the single source of truth or the displayed version and the released artifact will drift.

## Scope
- The packaging script derives the version from, in order: the `HONEYCRISP_VERSION` environment variable (set by the release workflow from the computed tag), then the latest git tag (`git describe --tags --abbrev=0`, leading `v` stripped), then a `0.0.0-dev` marker for a tagless checkout. It stamps that into the bundle's `CFBundleShortVersionString` and `CFBundleVersion`.
- `HoneycrispInfo.version` prefers the packaged bundle's `CFBundleShortVersionString` (stamped from the tag) and falls back to a compiled constant only for bare `swift run` dev builds, where there is no bundle to read. The bundled CLI inside the app resolves `Bundle.main` to the app bundle, so it reports the same tag-derived version.

## Out of scope
- The release workflow that sets `HONEYCRISP_VERSION` (HC-033).
- Notarization and signing (HC-032).

## Design
`HoneycrispInfo` exposes a pure `resolveVersion(bundleShortVersion:)` that returns the bundle string when present and non-empty, else `fallbackVersion`. The computed `version` feeds it `Bundle.main`'s value. Keeping the resolver pure makes the fallback rule testable without depending on the test runner's own bundle. The packaging script gains an output-capturing helper to read the tag.

## Test plan
New `HoneycrispInfoTests`:
- `resolveVersion(bundleShortVersion: "9.9.9")` returns `"9.9.9"` (a packaged version wins).
- `resolveVersion(bundleShortVersion: nil)` and `""` return `fallbackVersion` (dev and bare CLI fall back).

## Acceptance criteria
- No hardcoded marketing version remains as the source of truth; the tag drives the packaged artifact and what the app shows.
- The pure resolver is covered by tests and the suite stays green.
