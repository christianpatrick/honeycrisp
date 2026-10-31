# GH-18: Mail writes go straight to the message

## Why

Issue #18: single mail_mark_read calls fail with OSStatus -1712 after 20 seconds. The state writer finds a message with `message of inbox whose id = N`, which asks Mail to search the unified inbox across every account. On a big inbox, or while Mail is busy syncing, that search outlasts the 20 second timeout.

The same lookup also lies. A `whose` clause that matches nothing is not an error to Mail: `set` on zero messages succeeds quietly, so Honeycrisp reports `{"marked":1}` and the mail stays unread. On 2026-10-31 I reproduced this on my Mac with a promo in Junk. mail_mark_read answered `{"marked":1}` in about a second, and mail_search still showed the message unread. Anything outside an inbox fails this way, and so does a message that moved since the search.

mail_read already does better. Since GH-12, the body fetcher reads the message's mailbox url from the Envelope Index and addresses `message of mailbox "<path>" of account id "<uuid>" whose id = N`, which only searches one mailbox. Mark read, flag, and delete should take the same path, and should only report success after Mail confirms the change.

## Scope

- mail_mark_read, mail_update (read and flagged), and mail_delete address each message in its own account and mailbox, read from the Envelope Index, instead of the unified inbox.
- Success is confirmed by reading the state back from Mail. Read and flagged state must match what was asked. A deleted message must be gone from the mailbox it was in. Anything Mail does not confirm makes the call fail with a sentence saying which messages and why, so a partial or silent no-op is never reported as done.
- Because a message is addressed where it lives, these writes now work in any mailbox: Archive, Junk, custom folders, and On My Mac. The "Honeycrisp can only change inbox messages for now" error goes away.
- Deleting skips a message that is already in a Trash mailbox, because Mail's delete on a message in the Trash can erase it for good, and Honeycrisp's delete only ever means "move to the Trash". A thread delete moves everything else; a call where every message is already in the Trash is refused.
- A -1712 timeout becomes a readable error instead of a raw OSStatus.
- AGENTS.md records how writes target messages.

## Out of scope

- New tools, new catalog rows, or permission changes. The catalog stays at thirty-three actions and the approval set is unchanged.
- Undoing a partial thread change. When Mail confirms some messages of a thread and not others, the confirmed ones stay changed and the error says how many.
- Recovering a message that moved after the index was read. The error tells the client to search again.
- Batching several messages into one Apple event. One event per message per property keeps confirmation per message.

## Design

### Where a message lives

- `EnvelopeIndexReading` gains `mailboxURLs(forMessageIDs:)`, which reads `mailboxes.url` for each message ROWID in one query. MailDatabase implements it; ids that are not numeric or not in the index are left out of the answer.
- `MailService` turns message ids into `MailTarget` values (message id plus mailbox url) before calling the writer. An id the index does not know fails the call before any Apple event is sent: "No message matched the id ...".
- `MailboxLocation.isTrash` is true when the last path component, percent-decoded and compared without case, is Trash, Deleted Messages, Deleted Items, or Bin. iCloud uses Deleted Messages, Gmail `[Gmail]/Trash`, and Exchange Deleted Items. Names vary by provider and by language (Gmail's IMAP folders follow its web language, like `[Gmail]/Papierkorb`, and Outlook.com uses Deleted), so the name list is only half the check. `MailStateWriting.trashMailboxNames()` asks Mail for `name of every mailbox of trash mailbox`, the per-account mailboxes Mail itself files under its Trash, and a target whose path or last path component matches one of those, without case, counts as the Trash too. When Mail answers with no names, delete fails closed and sends nothing: "Mail did not say which mailbox is its Trash, so Honeycrisp deleted nothing." `MailService.delete` leaves Trash targets out before any delete is sent, and when nothing is left it refuses: "That message is already in the Trash, and Honeycrisp only moves mail to the Trash."

### Addressing in Mail

- The writer and the GH-12 body fetcher share one internal helper for Apple event plumbing: specifiers, the `whose id = N` test, the enabled account list (id, user name, server name in three gets), account matching through `MailboxLocation.accountID(among:)`, launching Mail in the background, and unwrapping list replies. The fetcher keeps its behavior: a failed user name or server name get leaves those fields empty instead of dropping every account, as the old per-get leniency did.
- The writer asks for the enabled accounts once per call, then for each target builds `message of mailbox "<path>" of account id "<uuid>" whose id = N`, or `message of mailbox "<path>" whose id = N` for a local:// mailbox. A target whose account cannot be matched, or whose account is disabled, is not confirmed.

### Confirmation

- Read and flagged: core/setd on `read status` (isrd) or `flagged status` (isfl) of the message specifier, then core/getd on the same property. The change counts only when the reply holds exactly one value equal to what was asked. A `whose` clause with no match answers getd with an empty list, which is exactly the false success this fixes.
- Delete: core/getd on the message's id first. No match means not confirmed and no delete is sent. Then core/delo, then core/getd on the id again. The delete counts only when the original mailbox no longer holds the message.
- The writer returns the ids Mail confirmed. `MailService` compares them with what it asked for. All confirmed returns the count as before. Otherwise it throws: for one message, "Mail did not confirm the change to message N. It may have moved since you searched; search again and retry." For several, "Mail confirmed M of N messages. Mail did not confirm these: ...". The wording never claims an unconfirmed message is untouched, because a delete may have been sent, or one of two properties may have changed. The confirmed ones keep their change.
- Error mapping on every event: -1743 keeps the Automation sentence, -1712 says "Mail took too long to answer. It may be busy syncing; try again in a moment.", and -1728 or -1719 (no such object) counts as not confirmed rather than an error. A delete counts as gone only when Mail answers the id check with zero matches; no answer at all is never read as gone, and a delete Mail rejects is not confirmed.
- A timeout or Automation block stops the batch. The writer throws `MailWriteStopped` carrying the ids it had already confirmed, and the service turns that into "Mail confirmed M of N messages before it stopped answering." followed by the reason, or the reason alone when nothing was confirmed yet.

### Tools

- The mail_update and mail_delete descriptions say they work in any mailbox instead of inbox messages.
- MailTools is otherwise unchanged. mark_read, update, and delete still call `markRead`, `setState`, and `delete` on `MailServicing` with message ids, and thread ids still resolve through `indexedThread`, so targeting never makes Mail download a body.

## Test plan

Failing tests first:

- MailDatabaseTests: `mailboxURLs(forMessageIDs:)` on the fixture index returns each message's mailbox url, skips ids that are not in the index or not numeric, and returns an empty map for an empty list.
- MailboxLocationTests (in MailLinkTests): `isTrash` for iCloud Deleted Messages, Gmail `[Gmail]/Trash` percent-encoded, Exchange Deleted Items, plain Trash in any case, and false for INBOX, Archive, Junk, and a folder named "Trash Talk".
- MailServiceTests with a fake index and a recording fake writer:
  - markRead and setState hand the writer each message with its mailbox url.
  - An id the index does not know throws before the writer is called.
  - A writer that confirms nothing makes markRead throw instead of returning 1, which is the Junk reproduction.
  - A writer that confirms part of a thread throws with the confirmed and missing counts.
  - Full confirmation returns the count.
  - delete refuses a single message in a Trash mailbox without calling the writer, skips the Trash messages of a thread, and deletes from Junk.
  - delete skips a mailbox Mail reports as its Trash under a localized name, and deletes nothing when Mail reports no Trash at all.
  - a writer that stops partway through a thread makes the error say how many changed, and a single stopped message passes the reason through.
- Integration, gated behind HONEYCRISP_INTEGRATION=1 and run on my Mac: the existing flag toggle and restore test goes through targets; a target with a real mailbox and an id that does not exist comes back unconfirmed with no error.
- Live, through a packaged build swapped in for my installed app: mark read a promo in Junk and an older inbox promo, and check mail_search shows each one read; toggle and restore a flag on a message outside the inbox; check what Mail answers for the Trash mailbox names on my accounts; and time single mark read calls.

## Acceptance criteria

- `swift build` and `swift test` pass, with red evidence recorded in the commit bodies.
- mail_mark_read on a message outside the inbox marks it read, verified live, and mail_search shows it read.
- No mail write reports success for a message Mail did not change.
- No mail write searches the unified inbox.
- Deleting a message already in the Trash is refused, and a thread delete leaves its Trash messages alone.
- The catalog stays at thirty-three actions and the approval set is unchanged.
- AGENTS.md records the targeting and confirmation rule in the same commit as the writer change.
