# HC-019: Probe the Envelope Index recipients schema at runtime

- Task number: HC-019 (no GitHub issue yet)
- Status: done
- Date: 2026-06-09

## Why

Reading a mail thread on the real Mac failed with "no such column: r.message_id". The HC-009 recipients query assumed the documented older schema (recipients.message_id and recipients.address_id), but this Mail version names those reference columns differently. Search never touches recipients, which is why it worked. Guessing schemas got us here, so the fix is to ask SQLite.

## Scope

- MailDatabase probes the recipients table once per connection with PRAGMA table_info and adapts: message_id or message for the message reference, address_id or address for the address reference, the type filter only when a type column exists, ordering by position only when it exists.
- Graceful degradation: when the recipients table is missing or unrecognizable, thread() still returns messages with senders, dates, and bodies, just with empty to lists. Recipients are a nicety; bodies are the point of mail_read.
- Regression fixtures: a modern-schema fixture (message, address columns) that reproduces the exact live failure red before the fix, and a no-recipients-table fixture asserting degradation. The legacy fixture keeps passing.
- Version 0.1.7, repackage, relaunch, and verify mail_read live against the real index through a real MCP client.

## Test plan

Failing first in MailDatabaseTests: the modern-schema fixture fails with the user's exact "no such column" error against the old query; the missing-table fixture throws instead of degrading. Both pass after the probe lands, and the legacy-schema tests stay green.

## Acceptance criteria

- All three schema shapes (legacy, modern, absent) pass in tests; the red runs are recorded in the commit body.
- mail_read returns real bodies on this Mac through the live app.
- swift test stays green; v0.1.7 packaged, running, tagged.
