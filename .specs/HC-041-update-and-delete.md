# HC-041: Update and delete across the apps

## Why

A user request: the connections can create and read almost everywhere, but they cannot change what exists. The motivating example is a reminder whose due date moved: today the only options are completing it or making a duplicate. Every app should carry its full lifecycle, create, read, update, and delete, wherever macOS gives us a sanctioned path.

## Scope

Eight new catalog actions, all writes, all off until the user raises an app to write:

- `reminders.update` and `reminders.delete` through EventKit.
- `calendar.update` and `calendar.delete` through EventKit.
- `contacts.update` and `contacts.delete` through the Contacts framework.
- `mail.update` (read and flagged state) and `mail.delete` (move to Mail's Trash) through raw Apple events, generalizing the HC-021 read marker.

## Out of scope

- Messages update and delete. There is no path that honors the architecture: no framework exists, chat.db writes are forbidden by rule, and the Messages scripting dictionary cannot edit or delete a message. Messages stays create (send) and read.
- Notes. HC-040 ships separately.
- Recurring event series edits. Update and delete touch one occurrence (span this event); series editing is a later task.
- Mail moves between arbitrary mailboxes. Delete goes to the Trash the way Mail itself deletes; a general move tool can come later.
- Attendee, alarm, and recurrence editing on events; label-level phone and email editing on contacts.

## Design

### Catalog

| Action | Label | Kind | defaultOn | requiresApproval |
| --- | --- | --- | --- | --- |
| reminders.update | Update a reminder | write | false | false |
| reminders.delete | Delete a reminder | write | false | false |
| calendar.update | Update an event | write | false | false |
| calendar.delete | Delete an event | write | false | false |
| contacts.update | Update a contact | write | false | false |
| contacts.delete | Delete a contact | write | false | false |
| mail.update | Update a message | write | false | false |
| mail.delete | Delete a message | write | false | false |

The catalog grows to twenty-eight actions across five apps. Nothing here leaves the Mac, so the approval invariant holds: requiresApproval stays exactly mail.send and messages.send. Deletes are guarded the way every write is guarded, by their switch and the app's write level, and every one lands in the audit log with what was deleted.

### Update semantics

Updates are partial: only the arguments present change, everything else stays. Two clearing rules keep the arguments flat:

- An empty string clears a clearable text field (reminder notes, event location and notes, contact phone, email, and organization) and an empty `due` clears a reminder's due date.
- A contact's `phone` or `email` replaces the whole list with that one value (mobile and home labels, matching contacts_create). The tool description says so plainly; label-level editing is out of scope.

Reminders update takes `title`, `due`, `notes`, `list` (moves it), and `completed` (false reopens a reminder that was completed by mistake). Calendar update takes `title`, `start`, `end`, `all_day`, `calendar` (moves it), `location`, `notes`; moving only `start` keeps the event's duration by shifting the end, and an `end` at or before the final start refuses with a sentence. Contacts update takes the create fields. Mail update takes `read` and `flagged` booleans, at least one required, over `message_id` or a whole `thread_id`.

### Services

- EKRemindersService: `update(ReminderUpdate)` and `delete(id:)`, fetching by calendarItemIdentifier, saving with commit. Delete returns the last snapshot so the audit can say what went away.
- EKCalendarService: `update(EventUpdate)` and `delete(id:)` over event(withIdentifier:), saving and removing with span this event.
- CNContactsService: `update(ContactUpdate)` and `delete(id:)` over a mutable copy and CNSaveRequest.
- Mail: the HC-021 read marker generalizes into AppleEventMailStateWriter, one seam that sets a boolean property (read status `isrd`, flagged status `isfl`) or sends the delete command (`core`/`delo`, which Mail routes to its Trash) on the inbox message whose id matches, exactly the HC-021 targeting including its inbox-only limitation and its -1728 sentence. MailServicing keeps `markRead` (the existing action rides it unchanged) and gains `setState` and `delete`.

### Tools

`reminders_update`, `reminders_delete`, `calendar_update`, `calendar_delete`, `contacts_update`, `contacts_delete`, `mail_update`, `mail_delete`. Ids come from the existing list and search tools, which already return them. Delete receipts echo the deleted item; audit copy names the thing in the service's own words ("Deleted the reminder", "The event was removed from your calendar").

## Test plan

Failing tests first, fakes for every framework:

- ActionCatalogTests: twenty-eight actions, per-app counts, the new rows spot-checked, approval set unchanged.
- RemindersToolsTests, CalendarToolsTests, ContactsToolsTests, MailToolsTests: the new actions translate arguments (partial updates, clears, the duration-preserving start move, the at-least-one-of rule for mail_update), produce receipts and audit copy, and refuse missing ids with sentences.
- Registry and gateway inventory: the read-tool set is unchanged; the new writes appear only at the write level.
- Integration, gated behind HONEYCRISP_INTEGRATION=1, self-cleaning: reminders and calendar and contacts each create a marked test item, update it, verify the change, delete it, and verify it is gone. Mail flags the newest inbox message and restores its exact prior state; mail delete has no safe self-cleaning form against real mail, so it ships on unit coverage plus the shared targeting path the flag test exercises.

## Acceptance criteria

- `swift build` and `swift test` pass with the new suites.
- The catalog holds twenty-eight actions across five apps and only the two sends require approval.
- A reminder's title, due date, notes, list, and completion state can change in place, and a reminder can be deleted, through the tools against a fake service and against real Reminders under the integration flag.
- The same is true for events and contacts, and mail messages can be flagged, unflagged, marked unread, and deleted through the same targeting mark_read uses.
- Messages ships no update or delete, and the spec records why.
- AGENTS.md reflects the new catalog count and the delete stance; the spec index records HC-041.
