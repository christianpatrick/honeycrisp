# HC-036: Harden the release pipeline

## Why
A security review of the release pipeline found two clusters of risk. First, the signing keys were exposed to unpinned third-party code: the release job ran `npm install` with no lockfile (hundreds of transitive packages) in the same job where the Sparkle private key and the notary key sat on disk and the signing keychain was unlocked, so one compromised npm dependency could steal the update key, which is unrotatable because the public key is baked into shipped apps. Second, release integrity gaps: the Sparkle signing tool was downloaded at release time without verification, actions were pinned by mutable tag, no checksums were published, CI had no least-privilege permissions, and SwiftPM `from:` ranges could float past `Package.resolved`.

## Scope
- Split the release into two jobs. The keyless job (Ubuntu, node) runs semantic-release to analyze commits, generate notes, create a draft release and the tag, and emit the version. The signing job (macOS, secrets) builds, signs, notarizes, Sparkle-signs, uploads the assets, and publishes the draft. The npm install never coexists with the signing keys.
- Pin the node toolchain: a committed `package.json` plus `package-lock.json`, installed with `npm ci`.
- Use the Sparkle `sign_update` tool that SwiftPM already fetches into the checksum-verified artifact (`.build/artifacts/.../bin/sign_update`), instead of downloading it. This removes the unverified download and the hand-maintained Sparkle version pin.
- Pin GitHub Actions to commit SHAs (with a version comment).
- Publish a `.sha256` checksum alongside the notarized zip (Sparkle's EdDSA signature already covers the auto-update path; the checksum is for manual downloads).
- Add `permissions: contents: read` to CI and pass `--force-resolved-versions` to SwiftPM in CI and packaging so dependencies cannot float past `Package.resolved`.
- Delete the key files and the temporary keychain at the end of the signing job (`if: always()`).

## Out of scope
- A protected-environment approval gate. The user chose to keep the release fully automatic; the job split, the pins, and the integrity checks still hold without it.

## Design
The isolation is the heart of it: semantic-release (and its npm dependency tree) runs where no signing key exists, and passes only the computed version forward as a job output. The signing job has the keys but installs no third-party node code; it builds with `--force-resolved-versions` so the pinned `Package.resolved` is authoritative, signs and notarizes through the existing packaging script, and gets `sign_update` from the SwiftPM artifact whose integrity SwiftPM already verified. The release is created as a draft so it only becomes visible (and only becomes the Sparkle feed's "latest") once the signed binary, appcast, and checksum are attached; a failed signing job leaves a harmless draft rather than a binary-less public release. Dependency bumps become deliberate: `swift package update` (or `npm install`) plus a committed lockfile, which is more secure than silent floating and still tracks latest.

## Test plan
CI and release infrastructure, exempt from unit tests. Verified locally where it runs locally: `package-lock.json` installs, `--force-resolved-versions` builds, and `sign_update` is present in the SwiftPM artifact. The two-job flow, notarization, and the draft publish are verified on the first real push.

## Acceptance criteria
- The job that runs `npm` has no signing secrets; the job with secrets installs no third-party node packages.
- No tool is downloaded unverified at release time; actions are SHA-pinned; CI is least-privilege; SwiftPM is pinned to `Package.resolved`.
- A release publishes only after the signed, notarized binary is attached, with a `.sha256` checksum.
