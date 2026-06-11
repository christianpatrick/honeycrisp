# HC-029: Calendar explicit range and calendars list

- Task number: HC-029 (no GitHub issue yet)
- Status: done
- Date: 2026-06-10

## Why

calendar_list only looks ahead from now by a day count; "what is on next Tuesday" should not require arithmetic. And calendar names are guessable only.

## Scope

- calendar_list gains from and to (ISO 8601) as an alternative to days: from defaults to now, to defaults to from plus days (default 7). The service speaks an explicit range, events(from:to:calendar:limit:), replacing the days-based signature.
- calendar_calendars, an alias tool riding calendar.list (executes "calendars"), returning calendar names.
- Ships as v0.3.0 together with HC-026 through HC-028: repackage, relaunch, live verification of timebound queries, commits, tag.

## Test plan

Failing first: translator window math (days default, explicit from/to, to without from), calendars routing, fake migrations; listing counts grow by one. Live: a real timebound query through the running app.

## Acceptance criteria

- New tests observed red, then green; the suite stays green.
- v0.3.0 packaged, running, tagged, with live timebound queries verified.
