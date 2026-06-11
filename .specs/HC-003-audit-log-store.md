# HC-003: Audit log store

- Task number: HC-003 (no GitHub issue yet)
- Status: done
- Date: 2026-06-09

## Why

The Activity tab is the design's accountability story: every request lands in an expandable row with an outcome badge, and the Status tab's glance tiles (Requests today, You approved) are computed from the same record. The store also embodies the privacy promise, so it is local, capped, and clearable, and it must never leave the Mac.

## Scope

- The AuditEntry model matching the catalog spec: app, action id, kind, outcome (allowed, denied, asked), the human sentence shown in the row, the client name, a timestamp, and the expandable detail (summary plus ordered label and value rows).
- An actor-backed store persisting JSONL at ~/Library/Application Support/honeycrisp/audit.jsonl: append, newest-first reads with an optional limit, tile counts, retention trimming, and clear.

## Out of scope

- Producing entries (HC-004 wires the server to the store), the notification approval flow (HC-005), and all UI (HC-011).

## Design

- Outcomes mirror the mock exactly: allowed (ran silently), denied (blocked by permissions or by the user or by timeout; the detail rows say which), asked (the user was asked and approved, badge "You approved").
- Entries serialize one JSON object per line with ISO8601 timestamps and sorted keys, so the file is greppable and diffs cleanly. Corrupt lines are skipped on load rather than poisoning the file, and load never throws.
- The store is an actor holding the decoded entries in memory (the cap keeps that small), appending a single line per entry, and rewriting the file only when trimming past maxEntries (config auditMaxEntries, default 2000) or clearing.
- Counts are computed against an injected now so tests are deterministic: requestsToday uses the calendar same-day test, approvedLastDay counts asked outcomes in the trailing 24 hours, matching the tile copy "in the last day".
- Append failures must never fail a user's tool call; the API throws and callers decide (HC-004 uses try? and surfaces nothing to the client).

## Test plan

AuditStoreTests, failing first:

- Appended entries come back newest first with every field intact, including detail rows.
- A second store instance on the same file sees the same entries (persistence).
- Counts: with a fixed noon "now", two same-day entries and one from yesterday give requestsToday 2; an asked entry from this morning counts toward approvedLastDay while an asked entry from 25 hours ago does not, and denied or allowed entries never count.
- Retention: cap 3, append 5, the oldest two are gone, and the file itself holds exactly 3 lines.
- clear empties the store and the file while leaving the file present.
- A corrupt line between two valid lines is skipped and both valid entries load.
- entries(limit: 2) returns the 2 newest.

## Acceptance criteria

- All tests above exist, were observed red before implementation (recorded in the commit body), and pass.
- The JSONL file format is one object per line, ISO8601 timestamps, sorted keys.
- swift test passes on this machine.
