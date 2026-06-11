# HC-012: Final verification, docs, v0.1.0

## Why

Everything is built and unit-verified; this task proves the product on this Mac through the packaged app, which is the real TCC identity, then finishes the docs and tags v0.1.0.

## Scope

- Launch dist/Honeycrisp.app and verify live: /health, initialize, tools/list over HTTP on the configured port; the stdio CLI bridging through the running app; a denied call writing a real audit entry; first TCC-gated calls attempted (their permission prompts belong to the user).
- Document exactly which behaviors still need the user's one-time grants or have real side effects (sends), so the user can finish the interactive verification at their convenience.
- Docs: README connect section gains the HTTP option and from-source install via the packaging script; AGENTS.md findings updated with anything HC-012 taught.
- Tag v0.1.0.

## Out of scope

- Public release plumbing (GitHub repo, Homebrew tap, notarization), per the local-only decision.

## Acceptance criteria

- The packaged app serves MCP on 127.0.0.1 with health, initialize, and gated tools/list verified live.
- The CLI bridges stdio through the running app, verified live.
- A permission denial round-trips live and lands in the real audit log.
- Remaining user-interactive verifications are listed precisely in the final report.
- The repo is tagged v0.1.0 with a clean tree and a green test suite.
