# HC-033: semantic-release pipeline

## Why
Releases should follow from conventional commits, not hand cranking. Merging work to main should compute the next version, build a notarized artifact, and publish it so the in-app updater (HC-034) has something to point at.

## Scope
- `.releaserc.json`: semantic-release with commit-analyzer, release-notes-generator, exec, and github. The exec `prepareCmd` builds and notarizes at the computed version, then makes the release archive and appcast. The github plugin uploads the notarized zip and `appcast.xml` as release assets.
- `.github/workflows/release.yml`: on push to main, a macOS runner imports the Developer ID certificate into a temporary keychain, stages the notarytool and Sparkle keys from secrets, fetches Sparkle's `sign_update`, and runs semantic-release.
- `scripts/make-release.swift`: zips the notarized app with ditto, signs it with Sparkle's `sign_update`, and writes `dist/appcast.xml` whose enclosure points at the release download URL.
- `node_modules/` added to `.gitignore`.

## Out of scope
- The eight repository secrets (the user creates these).
- The in-app Sparkle dependency, feed URL, and public key (HC-034).

## Design
One job, one source of truth. semantic-release computes the version from the commits; the `exec` plugin threads it through `HONEYCRISP_VERSION` so the build (HC-031) and the packaging (HC-032) stamp and notarize the right version. Everything runs in the same job, so the default `GITHUB_TOKEN` is enough and no token with extra scope is needed; release notes live on the GitHub release rather than committed back, so branch protection on main is untouched. The workflow passes the certificate's common name (not its hash) as `HONEYCRISP_SIGN_IDENTITY` so the packaging script's Developer ID detection fires. The Sparkle tool version is pinned and may need bumping over time.

## Test plan
Build and release infrastructure, exempt from unit tests. Locally: `.releaserc.json` parses as JSON and `make-release.swift` compiles and guards its required environment. The pipeline end to end is verified on the first real push, which needs the repo secrets, a GitHub remote, and Apple notarization.

## Acceptance criteria
- A push to main with a `feat`/`fix` commit cuts a release, attaches a notarized `Honeycrisp-<version>.zip` and `appcast.xml`, and tags `v<version>`.
- A push with only chore/docs commits makes no release.
- The version on the artifact matches the tag.
