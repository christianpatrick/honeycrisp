# HC-038: CodeQL advanced setup with a manual Swift build

## Why
GitHub's CodeQL default setup cannot scan this repository. Swift analysis traces a real compile, and default setup's autobuild runs the stock toolchain on a GitHub-managed macos-15 runner, where the build dies in HoneycrispCore with a strict concurrency error (sending 'db' risks causing data races, ChatDatabase.swift line 82). The code is correct under the toolchain this project builds with, Xcode 26.x on macos-26, which is why CI passes; the macos-15 image carries an older Swift that rejects it, and default setup offers no way to choose the runner or the build command. The failed run is https://github.com/christianpatrick/honeycrisp/actions/runs/27375950484, and its own error message prescribes the fix: switch the language to manual build mode with explicit build steps.

## Scope
- A committed advanced setup workflow, .github/workflows/codeql.yml, that analyzes Swift on macos-26 with build-mode manual and `swift build --force-resolved-versions` as the build step, matching the toolchain and dependency pinning CI uses.
- HC-036 hygiene throughout: actions pinned to commit SHAs, a contents read default with security-events write granted only to the analyze job.
- Upload category /language:swift, the category default setup was using, so any existing alerts carry over instead of duplicating.
- Record the decision in AGENTS.md.

## Out of scope
- Making the code compile on older toolchains. The macos-15 failure is a property of an unsupported compiler, not a bug; AGENTS.md pins the project to Xcode 26.x and Swift 6.x.
- Repository settings. Turning default setup off is a one-time admin action in Settings, Advanced Security, Code scanning; it cannot be committed to the repository. Until it is off, GitHub rejects SARIF uploads from any advanced workflow.
- Scanning GitHub Actions workflows or other extra languages. Swift is the codebase (AGENTS.md: every bit of this project is native Swift).

## Design
The workflow mirrors ci.yml: push to main, pull requests, a concurrency group per ref, plus a weekly cron so new queries still run on quiet weeks. One job on macos-26 checks out, runs codeql-action/init with languages swift and build-mode manual, builds with `swift build --force-resolved-versions` (production targets only, tests are not part of the shipped surface), then runs codeql-action/analyze with the /language:swift category. CodeQL 2.25.6, the bundle pinned by codeql-action v4.36.2, supports Swift through 6.3.2, which covers the default Xcode 26.4.1 toolchain on the macos-26 image.

## Test plan
CI scaffolding, the same exemption HC-032 and HC-036 took: no unit test can exercise a hosted workflow. Verified instead by the workflow YAML parsing and by the first real run on GitHub once default setup is switched off: the Analyze Swift job must build and upload results successfully.

## Acceptance criteria
- .github/workflows/codeql.yml exists, parses, pins both actions to commit SHAs, and grants security-events write to the analyze job only.
- The build step is `swift build --force-resolved-versions` on macos-26 with build-mode manual, and the analyze step uploads with category /language:swift.
- AGENTS.md records that code scanning is the committed advanced setup workflow and that default setup must stay off.
- After default setup is disabled in the repository settings, the workflow's first run completes green and results appear under code scanning.
