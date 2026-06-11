# HC-028: Reminders due window and lists

- Task number: HC-028 (no GitHub issue yet)
- Status: done
- Date: 2026-06-10

## Why

reminders_due answers today; nothing answers "due this week" or "overdue". And the model guesses list names because nothing enumerates them.

## Scope

- reminders_list gains due_after and due_before (ISO 8601). When a window is given, reminders without a due date are excluded, since a window is a question about dates. "Overdue" is due_before now.
- reminders_lists, an alias tool riding reminders.list (executes "lists"), returning the list names.
- RemindersServicing grows the window parameters and listNames(); EKRemindersService filters dates inside the fetch callback and lists the reminder calendars' titles.

## Test plan

Failing first: translator pass-through of the window and the no-due-date exclusion contract (documented in the protocol), lists routing and audit copy, ISO failures via the shared dateArg sentence; listing counts grow by one.

## Acceptance criteria

- New tests observed red, then green; the suite stays green.
