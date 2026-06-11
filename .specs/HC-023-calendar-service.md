# HC-023: Calendar service

## Why

Calendar is the fifth app, requested by Christian, with a hand-built icon shipped in assets/. "What is on today" sits naturally beside "what is due today", and creating events closes the capture loop. Per the AGENTS.md hierarchy this is tier 1: EventKit for reads and writes both, the same framework story as Reminders.

## Scope

- AppID gains .calendar (catalog order: mail, reminders, calendar, messages, contacts). Old configs heal through the existing normalization: default level read, reads on.
- Three actions (twenty total): calendar.today "Check what is on today" (read, on), calendar.list "List upcoming events" (read, on), calendar.create "Create an event" (write, off, no approval). EventKit cannot attach attendees programmatically, so created events cannot send invites and nothing leaves the Mac; the default-off switch keeps the write deliberate, preserving the invariant that write switches default off under a default read level.
- Tools: calendar_today (no arguments), calendar_list (days, defaulting to 7, calendar, limit), calendar_create (title and ISO 8601 start required; end defaulting to one hour later; all_day, calendar, location, notes optional).
- Domain: CalendarEvent (id, title, calendar, start, end, allDay, location, notes), NewEvent, CalendarServicing (today, upcoming, create), CalendarTools translator, EKCalendarService over EKEventStore full access (events sorted by start; create into the named calendar or the default, saving the single event).
- App surfaces: the panel and Simple and Advanced permissions pick the app up from the catalog automatically; the onboarding access step gains a Calendar row prompting in place; the app icon ships from the delivery's calendar.svg with an SF Symbol fallback; the Info.plist gains the calendars usage strings.
- Copy sweep from four apps to five: README tagline, intro, and table; AGENTS.md; the server instructions string in both response builders; the CLI help and the --apps error sentence.
- Gated integration test: create, fetch, and remove a uniquely titled event against the real store (Terminal-run).
- Version 0.2.0 (a new app integration is a minor bump), repackage, relaunch, live verify calendar_today through the running app.

## Out of scope

- Attendees and invitations (EventKit cannot write them), responding to invitations, recurring event editing, and deleting events.

## Test plan

Failing first: ActionCatalogTests move to twenty actions, five apps, with calendar spot checks; PermissionEngineTests assert calendar defaults (today allowed, create denied readOnlyApp); CalendarToolsTests with a fake service cover today's copy, list's day defaulting and pass-through, create's field mapping, ISO parsing and validation failures, and executor routing for calendar.

## Acceptance criteria

- All new tests were observed red and pass; the suite stays green.
- calendar_today returns real events through the live app once the Calendar grant is given.
- v0.2.0 packaged, running, tagged.
