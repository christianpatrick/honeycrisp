# GH-12: Mail links and missing bodies

## Why

Issue #12 names two gaps in Mail reads.

First, mail_search and mail_read return only Honeycrisp's numeric ids, so an agent has nothing tappable to hand back on a phone. Mail answers `message://` URLs built from a message's RFC Message-ID, and a live check on 2026-10-22 opened the same email from one such link on both macOS and iOS (a DistroKid message forwarded from HEY into iCloud, linked by its Message-ID, not the Resent-Message-ID iCloud added). The Envelope Index already stores that header, so every row can carry a link for the cost of one join.

Second, mail_read reports "(body unavailable)" for archived mail Mail has not downloaded to disk. No .emlx exists for those messages, and we never write Mail's store, so the only sanctioned way to get the body is to ask Mail for it.

## Scope

- A `link` field on every row mail_search and mail_read return (MailMessageSummary and MailMessage), and on the messageSummary lookup that reply resolution uses.
- A body fallback in mail_read: when a message has no readable .emlx, Honeycrisp asks Mail for the message source over a raw Apple event and parses it with the existing MIME code.
- One recorded exception to the AGENTS.md rule that Apple events are only for writes.

## Out of scope

- A separate mail_link tool. The link rides the rows, unlike notes_link.
- Widening HC-021 and HC-041 targeting (mark read, flag, delete) beyond the inbox. The mailbox specifier built here makes that possible later.
- Web links (icloud.com, Gmail web), links for other apps, and the Resent-Message-ID.
- Attachment downloads and body text search.

## Design

### Link

- Envelope Index facts: `messages.global_message_id` references `message_global_data.ROWID`, whose `message_id_header` column holds the RFC Message-ID. MailDatabase probes both columns once through PRAGMA table_info, the way it probes recipients, and an index without them degrades to a null `link` instead of failing the query.
- Search, thread, and messageSummary LEFT JOIN `message_global_data` and select the header.
- A small MailLink builder turns the header into the URL: trim whitespace and one pair of surrounding angle brackets, percent-encode every character except RFC 3986 unreserved characters and `@`, then wrap the result as `message://%3C` + id + `%3E`. An empty or missing header yields nil.
- JSON key `link` (the snake case encoder leaves it as is). The mail_search and mail_read descriptions say each row carries a link that opens the message in Mail on this Mac and on an iPhone or iPad signed into the same account.

### Body fallback

- MailDatabase keeps reading .emlx files exactly as today. For each message whose body it could not read, it reports the message's mailbox url alongside the thread, outside the JSON.
- MailService.thread hands those misses to a new MailBodyFetching seam (AppleEventMailBodyFetcher in production) and runs the returned source through Emlx.bodyText(fromRFC822:), the same parser the .emlx path uses. Messages with a body on disk never reach the fetcher, so a fully downloaded thread sends no Apple events.
- Targeting: `message of (mailbox <path> of (account whose id = <uuid>)) whose id = N`. The account id comes from the mailbox url's host and the mailbox path from its percent-decoded path, with nested mailboxes named by Mail's slash-separated path. Mailboxes outside an account (On My Mac) drop the account level. The message id is the Envelope Index ROWID, the same id HC-021 targets.
- The event is core/getd on the message's `source` property (code `raws` in Mail.sdef). Mail fetches the message from its server to answer, which stores the body in Mail's own store through Mail's own path. Honeycrisp writes nothing.
- Mail is launched first when it is not running, like the composer and state writer. Each fetch uses the existing 20 second timeout, and the thread limit bounds how many fetches one call can make.
- Failure degrades per message and never fails the thread: a timeout, a missing message, or an empty source keeps "(body unavailable)". An Automation denial replaces the placeholder with the System Settings sentence the state writer already uses, so the user learns how to fix it.
- Audit copy for mail_read adds "Mail downloaded N bodies it did not have yet." when N is above zero.

### Permissions and architecture

- No catalog change: the catalog stays at thirty-three actions, the link rides mail.search and mail.read, and the fetch rides mail.read. requiresApproval stays exactly mail.send and messages.send, because the fetch sends nothing of the user's off the Mac.
- AGENTS.md tier 3 gains one sentence: fetching a Mail body that is not on disk yet is the single Apple event read, allowed because no store-safe path exists and Mail performs the download itself.

## Test plan

Failing tests first:

- MailLinkTests: bare and bracketed headers produce the same URL, `+`, `=`, `/`, `$`, and `%` are percent-encoded, `@` stays, and empty input yields nil.
- MailDatabaseTests: the fixture index gains `message_global_data` and `global_message_id`; search rows, thread messages, and messageSummary carry the expected link; a fixture without the table returns rows with a null link; a thread with a missing .emlx reports that message's mailbox url as a miss.
- Mailbox specifier parsing: imap urls with a UUID host, nested and percent-encoded paths, and a local mailbox map to the right account id and path.
- MailService tests with a fake reader and a fake fetcher: misses reach the fetcher with their mailbox urls, fetched RFC822 is parsed to its text/plain part, no fetch happens when every body is on disk, a fetch failure keeps the placeholder, and an Automation denial yields the System Settings sentence.
- MailToolsTests: the JSON carries `link`, and the audit copy counts downloaded bodies.
- Integration, gated behind HONEYCRISP_INTEGRATION=1: the newest inbox message's link matches the Message-ID in its .emlx headers. The fetch test runs first, before any production fetch code exists: it picks a message with no .emlx, fetches its source, and asserts that a body comes back and the message's read flag is unchanged afterward. If Mail returns an empty source for an undownloaded message, this spec gets revised before code.
- Live: open a link from an iPhone for a Message-ID containing `+` and `=` (a Gmail-style id), to confirm Mail decodes the escapes.

## Acceptance criteria

- `swift build` and `swift test` pass, with red evidence recorded in the commit bodies.
- Every mail_search and mail_read row carries a `link` that opens the message in Mail on the Mac and on an iPhone, verified live.
- mail_read returns real bodies for archived messages Mail had not downloaded, without changing their read state.
- An Envelope Index without `message_global_data` still answers searches, with null links.
- The catalog stays at thirty-three actions and the approval set is unchanged.
- AGENTS.md records the Apple event read exception in the same commit that adds the fetcher.
