# HC-001: Repo scaffold

## Why

The repository starts empty. Christian locked the foundational decisions up front: the menu bar app is the hub, outbound writes are real sends behind notification approval, there is no GitHub remote yet so specs use task numbers, the minimum is macOS 15, every bit of the project is native Swift, osascript is banned, and nothing ever writes a data store another app owns. Those rules need to live in the repo before any behavior is built.

## Scope

- .gitignore for SPM and macOS noise.
- LICENSE: MIT, Christian Helvin, 2026.
- AGENTS.md: what Honeycrisp is, the architecture decisions, the app-access hierarchy, the permission model, the process rules (spec first, strict TDD with recorded red evidence, meaningful tests, conventional commits), the voice rules, and a findings log that grows.
- CLAUDE.md as a pointer to AGENTS.md.
- CONTRIBUTING.md in the project voice.
- .spec/README.md: the spec process, template, and index.
- assets/: the README image set (banners, app icons, marks) at the paths the README expects.
- README.md with three honest framing choices: macOS 15 stated, install copy reflects the menu bar app with a bundled CLI and the not-yet-live tap, and the privacy lines account for the local activity list.
- Package.swift with a HoneycrispCore library target and a version constant, so swift build is green from the first commit.

## Out of scope

- Any behavior, any tests, MCP wiring, the CLI and app targets, packaging, CI.

## Design

All decisions are recorded in AGENTS.md, which is the binding document. The spec index in .spec/README.md mirrors the twelve planned tasks (HC-001 through HC-012).

## Test plan

None. Scaffolding, assets, and docs are TDD-exempt per AGENTS.md process rule 2. Verification is `swift build` succeeding on a clean checkout and the README rendering its images from assets/.

## Acceptance criteria

- `swift build` succeeds from the repo root.
- AGENTS.md, CLAUDE.md, CONTRIBUTING.md, LICENSE, README.md, and .specs/README.md exist with the content described above.
- README image paths resolve against assets/.
