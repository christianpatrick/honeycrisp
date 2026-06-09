# Specs

Every task in this repository starts as a spec in this folder, written and committed before the code. Specs are numbered HC-NNN in the order the work was planned. There is no GitHub remote yet, so specs reference their task number; if the project gains a GitHub repo, newer specs reference issue numbers instead.

A spec is done when its acceptance criteria are verifiably true on this machine, with the test evidence the spec called for.

## Template

```markdown
# HC-NNN: Title

- Task number: HC-NNN (no GitHub issue yet)
- Status: draft | accepted | done
- Date: YYYY-MM-DD

## Why
What problem this solves and where the requirement comes from (the product spec, AGENTS.md decision, user request).

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
| HC-008 | Messages service | planned |
| HC-009 | Mail service | planned |
| HC-010 | Loopback HTTP transport, CLI bridge, client tracking | planned |
| HC-011 | Menu bar app | planned |
| HC-012 | Final verification, docs, v0.1.0 | planned |
