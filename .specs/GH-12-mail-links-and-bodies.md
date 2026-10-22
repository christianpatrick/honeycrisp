# GH-12: Mail links and missing bodies

## Why

Issue #12 names two gaps in how Honeycrisp reads Mail.

First, mail_search and mail_read only hand back Honeycrisp's numeric ids, so when an assistant finds an email for me there is nothing I can tap on my phone. Mail answers `message://` links built from a message's RFC Message-ID. On 2026-10-22 I opened one by hand, a DistroKid email that HEY forwarded into iCloud, and it went straight to the message on both my Mac and my iPhone. The link used the Message-ID, not the Resent-Message-ID iCloud added on the way in. Mail's Envelope Index already keeps that header, so every row can carry a link for the cost of one join.

Second, mail_read says "(body unavailable)" for archived mail that Mail never downloaded to my Mac. There is no .emlx file for those messages, and Honeycrisp never writes to Mail's store, so the only honest way to get the body is to ask Mail for it.

## Scope

- A `link` on every row mail_search and mail_read return, and on the single message lookup that reply drafting uses.
- A body fallback in mail_read: when a message has no readable .emlx, Honeycrisp asks Mail for the message source with a raw Apple event and parses it with the MIME code it already has.
- One recorded exception to the AGENTS.md rule that Apple events are only for writes.
- The Mail line in the README and on the website mentions the link.

## Out of scope

- A separate mail_link tool. The link rides the rows, unlike notes_link.
- Links for rows the Envelope Index has no Message-ID for. macOS 15 never stored the header, and macOS 26 does not fill it for every row. Recovering those from .emlx headers can come later.
- Widening HC-021 and HC-041 targeting (mark read, flag, delete) beyond the inbox. The mailbox addressing built here makes that possible later.
- Web links (icloud.com, Gmail on the web), links for other apps, and the Resent-Message-ID.
- Attachment downloads and searching body text.

## Design

### The link

- What the Envelope Index holds: on macOS 26, `message_global_data.message_id_header` is the RFC Message-ID. `messages.message_id` is not the header despite its name. It is a 64-bit hash of the header, and `message_global_data.message_id` holds the same hash, so the two tables join on it. macOS 15 has the table without the header column.
- MailDatabase probes for `messages.message_id`, `message_global_data.message_id`, and `message_global_data.message_id_header` once, the same way it probes recipients. When any of them is missing, the queries select NULL in that slot and skip the join, and rows come back without a link instead of failing.
- Search, thread, and the single message lookup LEFT JOIN `message_global_data g ON g.message_id = m.message_id` and select the header.
- MailLink turns a header into a URL. It trims whitespace and one pair of angle brackets, percent-encodes every character except the RFC 3986 unreserved set and `@`, then wraps the id as `message://%3C` + id + `%3E`. An empty or missing header gives no link. The JSON encoder leaves nil optionals out, so a row without a link has no `link` key at all.
- The mail_search and mail_read descriptions tell clients each row carries a link that opens the message in Mail on the Mac and on an iPhone or iPad with the same account.

### Missing bodies

- MailDatabase keeps reading .emlx files exactly as it does today. For each message it could not read a body for, it records the message id and its mailbox url on the thread, outside the JSON.
- MailService.thread hands those to a new MailBodyFetching seam, AppleEventMailBodyFetcher in production, and runs each returned source through MimeText.bodyText(fromRFC822:), the same parser the .emlx path uses. A thread with every body on disk never sends an Apple event.
- Write targeting does not fetch. mark_read, update, and delete resolve a thread_id to message ids through a new indexedThread call that reads the Envelope Index only, so flagging a thread never makes Mail download anything.
- Finding the message in Mail: the mailbox url looks like `imap://user@server/INBOX/Receipts`, or carries the account's UUID as its host on some versions, and `local://` urls name mailboxes On My Mac. The fetcher asks Mail once per call for the id, user name, and server name of every enabled account, and matches in this order: an id equal to the url host, the one account on that server, the one account on that server with that user name, then the only account if there is just one. The mailbox is addressed by its percent-decoded path, which is how Mail names nested mailboxes, and the message by `whose id = N` with the Envelope Index ROWID, the same id HC-021 targets. Local mailboxes skip the account.
- The event is core/getd on the message's `source` property, code `raso` in Mail.sdef. Mail fetches the message from its server to answer and keeps the body in its own store through its own path. Honeycrisp writes nothing.
- Mail is launched in the background when it is not running, like the composer and the state writer do. Each event uses a 20 second timeout, and the thread limit caps how many fetches one call can make.
- A failed fetch never fails the thread. A timeout, a message Mail cannot find, or an empty source leaves "(body unavailable)". When macOS blocks Automation, the missing bodies say so and carry the same System Settings sentence the state writer uses, so I know how to fix it.
- When Mail downloads anything, the mail_read audit copy says "Mail downloaded N bodies it did not have yet." and adds a Downloaded row.

### Permissions and architecture

- No catalog change. The catalog stays at thirty-three actions, the link rides mail.search and mail.read, and the fetch rides mail.read. requiresApproval stays exactly mail.send and messages.send, because the fetch sends nothing of mine off the Mac.
- AGENTS.md tier 3 gains one sentence: fetching a Mail body that is not on disk yet is the single Apple event read, allowed because no store-safe path exists and Mail does the download itself.

## Test plan

Failing tests first:

- MailLinkTests: bare and bracketed headers give the same URL, the DistroKid id from my live check gives exactly the link I tapped, `+`, `=`, `/`, `$`, and `%` get percent-encoded, `@` stays, and empty input gives nil.
- MailboxLocationTests: imap urls with a user and server, a UUID host, nested and percent-encoded paths, and a local mailbox parse to the right parts, and account matching follows the order above, including no match when two accounts tie.
- MailDatabaseTests: the fixture index gains the hash column and `message_global_data`. Search rows, thread messages, and the single lookup carry the expected link. A macOS 15 shaped fixture without the header column returns rows with no link. A thread with a missing .emlx records that message's mailbox url.
- MailServiceTests with a fake reader and a fake fetcher: missing bodies reach the fetcher with their mailbox urls, fetched source is parsed to its text/plain part, a thread with every body on disk never calls the fetcher, indexedThread never calls it either, a fetch error keeps the placeholder, and an Automation block puts the System Settings sentence in the missing bodies.
- MailToolsTests: the JSON carries `link`, the audit copy counts downloaded bodies, and thread targeting for mark_read goes through indexedThread.
- Integration, gated behind HONEYCRISP_INTEGRATION=1 and run on my Mac: recent rows carry well-formed links when the index has the header, and the fetcher returns a body for a message with no .emlx without changing its read state. If Mail returns an empty source for a message it has not downloaded, I revise this spec before relying on the fallback.
- Live: tap a link from my iPhone for a Message-ID with `+` and `=` in it, like a Gmail id, to confirm Mail decodes the escapes.

## Acceptance criteria

- `swift build` and `swift test` pass, with red evidence recorded in the commit bodies.
- Every mail_search and mail_read row with a Message-ID in the index carries a `link` that opens the message in Mail on my Mac and on my iPhone, verified live.
- mail_read returns real bodies for archived messages Mail had not downloaded, without changing their read state.
- An Envelope Index without the header column still answers searches, with no links.
- Marking, flagging, and deleting a thread never triggers a download.
- The catalog stays at thirty-three actions and the approval set is unchanged.
- AGENTS.md records the Apple event read exception in the same commit that adds the fetcher.
