# HC-007: Reminders service

## Why

Reminders is the everyday-utility app of the four (the mock's audit log leads with "Checked what is due today") and the first service with writes that run without approval: creating and completing reminders are local writes, on by default per the catalog. Per AGENTS.md this is tier 1 access: EventKit for reads and writes both.

## Scope

- Domain types: Reminder (id, title, notes, list, due date, completed) and NewReminder.
- RemindersServicing protocol: reminders(list:includeCompleted:limit:), dueToday(limit:), create(_:), complete(id:).
- RemindersTools translator: routes the four actions, applies config defaults (defaultLimit, defaultRemindersList), parses ISO 8601 due dates in three shapes (full with zone, local without zone, date only), and writes mock-voiced audit copy.
- ToolDates: the shared ISO 8601 parsing helper.
- EKRemindersService: the real EventKit implementation (full access request, list filtering by calendar title, due-today as overdue plus today via the incomplete-reminders predicate, create into the named or default list, complete by calendar item identifier).
- Gated integration test: create, find, complete, and remove a uniquely titled reminder against the real store.

## Out of scope

- Recurring reminder semantics (the first occurrence's due date is what we report), priorities, and subtasks. The other services and all UI.

## Design

- reminders_list defaults include_completed to false, list to config defaultRemindersList (nil means all lists), and limit to config defaultLimit. An explicit list argument overrides the config default.
- reminders_due is incomplete-only, due today or overdue, matching what a person means by "what is due today". Its audit action is the mock's exact sentence: "Checked what is due today", and its rows include Wrote: Nothing like the mock's entry.
- reminders_create requires a title; an unparseable due string is a ToolFailure naming ISO 8601. The due row formats through en_US_POSIX so tests are locale-stable.
- reminders_complete requires an id; unknown ids surface the service's sentence.
- Sorting: due dates ascending with no-due-date entries last, so limits keep the most actionable items.

## Test plan

RemindersToolsTests with a fake service, failing first:

- list passes config defaults (no completed, config list, config limit) and round-trips JSON.
- An explicit list argument overrides the config default; include_completed and limit arguments pass through.
- due routes to dueToday with the mock's audit sentence and a Wrote: Nothing row.
- create maps title, notes, list, and a local-time ISO due date onto NewReminder deterministically.
- create with a date-only due string parses to local midnight; an invalid due string is a ToolFailure mentioning ISO 8601.
- create without a title and complete without an id are ToolFailures.
- complete passes the id and audits "Marked ... as done".
- An unknown reminders action is a ToolFailure.
- ServiceExecutor routes reminders actions when wired.

RemindersIntegrationTests, gated behind HONEYCRISP_INTEGRATION=1 (Terminal-run per the AGENTS.md TCC finding):

- Round trip: create a uniquely titled reminder, find it in a list call, complete it, verify completion, then remove it.

## Acceptance criteria

- All unit tests above exist, were observed red before implementation (recorded in the commit body), and pass.
- swift test (ungated) stays green; the integration round trip is runnable from a TCC-capable terminal.
