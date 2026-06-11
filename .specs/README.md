# Specs

Every task in this repository starts as a spec in this folder, written and committed before the code. Specs are numbered HC-NNN in the order the work was planned. The status of each one lives in the index below.

A spec is done when its acceptance criteria are verifiably true on this machine, with the test evidence the spec called for.

## Template

```markdown
# HC-NNN: Title

## Why
What problem this solves and where the requirement comes from (an AGENTS.md decision, a user request).

## Scope
What this task delivers.

## Out of scope
What it deliberately does not touch.

## Design
How it works: data model, APIs, edge cases, error behavior.

## Test plan
The failing tests to write first, what each asserts, and which are TCC-gated integration tests.

## Acceptance criteria
Checkable statements that make this task done.
```

## Index

| Spec | Title | Status |
| --- | --- | --- |
| HC-001 | Repo scaffold | done |
| HC-002 | Permission engine and config model | done |
| HC-003 | Audit log store | done |
| HC-004 | MCP server core with tool catalog and gating | done |
| HC-005 | Approval broker | done |
| HC-006 | Contacts service | done |
| HC-007 | Reminders service | done |
| HC-008 | Messages service | done |
| HC-009 | Mail service | done |
| HC-010 | Loopback HTTP transport, CLI bridge, client tracking | done |
| HC-011 | Menu bar app | done |
| HC-012 | Final verification, docs, v0.1.0 | done |
| HC-013 | v0.1.1 fixes: structuredContent shape, collapsed panel, stable signing | done |
| HC-014 | Chrome consistency and in-app copy trim | done |
| HC-015 | Bring the Settings window to the front | done |
| HC-016 | Simple mode Read & write enables every action | done |
| HC-017 | Equal glance tiles and a visible menu bar glyph | done |
| HC-018 | Settings opens on the current Space | done |
| HC-019 | Probe the Envelope Index recipients schema at runtime | done |
| HC-020 | Readable text from HTML-only mail | done |
| HC-021 | Mark mail as read | done |
| HC-022 | The wordmark in the app | done |
| HC-023 | Calendar service | done |
| HC-024 | Whole-segment tap targets | done |
| HC-025 | Remove the misleading messages_draft action | done |
| HC-026 | Messages query dimensions: history, time bounds, unread filter | done |
| HC-027 | Mail query dimensions: filters-first search and mailbox discovery | done |
| HC-028 | Reminders query dimensions: due window and list discovery | done |
| HC-029 | Calendar query dimensions: explicit range and calendar discovery | done |
| HC-030 | Automatic update checks preference | done |
