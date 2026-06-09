# HC-016: Simple mode "Read & write" enables every action

- Task number: HC-016 (no GitHub issue yet)
- Status: done
- Date: 2026-06-09

## Why

Christian set every app to Read & write in Simple mode, switched to Advanced, and saw only the read actions on (2 of 4, 2 of 5, 2 of 3): the level said Read & write while the app behaved read-only. The HC-002 semantics were faithful to the original spec (write turned reads on and left write switches untouched, preserving Advanced curation), but they made the common path dishonest: Read forces writes off, so Read then Read & write silently kept writes off.

## Scope

- setLevel(.write) now turns every action on. Simple mode becomes blunt and predictable: Off is nothing, Read is reads only, Read & write is everything. Outbound sends keep their mandatory per-request approval regardless, so the safety story is unchanged.
- Off and Read keep their semantics (everything off; reads on, writes off). Advanced remains the curation surface, and curating there still auto-raises the level so switches are always effective.
- This supersedes the level-change table in HC-002. AGENTS.md's permission model section is updated to match.
- Version 0.1.4, repackage, relaunch.

## Test plan

Failing first: PermissionEngineTests' raise-to-write expectation flips from "draft and send stay off" to "every action turns on, and an enabled send still needs approval rather than plain allowed."

## Acceptance criteria

- The updated test was observed red against the old semantics and passes after.
- In the app: Simple Read & write everywhere, then Advanced, shows every action on.
- swift test stays green; v0.1.4 packaged, running, tagged.
