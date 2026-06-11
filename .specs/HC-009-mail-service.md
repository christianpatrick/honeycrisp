# HC-009: Mail service

## Why

Mail is the headline integration ("Pull the thread you half remember, summarize it, and draft a reply that sounds like you") and the last of the four. Reads come from Mail's Envelope Index SQLite plus the .emlx files on disk, both read-only (tier 2). Drafts and sends are raw in-process Apple events to Mail (tier 3); a draft is a local write that lands in the Drafts mailbox, a send is outbound and approval-gated at the gateway. Nothing here ever writes a store Mail owns.

## Scope

- Domain types: MailMessageSummary (id, thread id, subject, from address and name, date, mailbox, read), MailMessage, MailThread, MailDraft, MailComposeReceipt.
- MailServicing protocol: search, thread(id:limit:), messageSummary(id:) for reply resolution, draft, send.
- MailTools translator: requires a query for search and a thread id for read; draft and send accept to, cc, subject, body, and reply_to_message_id, where a reply with no explicit recipients resolves the original sender and a Re: subject through messageSummary. Audit copy follows the mock ("Read the thread", "Returned the subject and N message bodies. Nothing was modified.").
- MailDatabase: an actor over the Envelope Index (discovered as the highest ~/Library/Mail/V* version at runtime, injectable for tests), joining messages to subjects, addresses, mailboxes, and recipients. Dates are Unix seconds. Bodies come from .emlx files found by one bounded filename walk per thread (the on-disk sharding varies by Mail version, so we search for ROWID.emlx and ROWID.partial.emlx rather than guessing the shard layout); a missing file reads "(body unavailable)".
- Emlx and MimeText: parse the .emlx length-prefixed RFC822 payload, unfold headers, walk multipart bodies preferring text/plain over de-tagged text/html, and decode quoted-printable and base64 with a UTF-8 then Latin-1 charset fallback.
- AppleEventMailComposer: raw Apple events to com.apple.mail. Compose is core/crel of class bcke with subj, ctnt, and pvis false, then trcp (and ccrc) recipients created at the end of the message's recipient elements with radd addresses. Draft finishes with core/save (into Drafts); send finishes with emsg/send. Automation denial maps to the System Settings sentence; Mail is launched first when not running.
- Shared internal SQLite helpers extracted from ChatDatabase so both databases use one set.
- Gated integration test: search and thread against the real Envelope Index (Full Disk Access, Terminal-run).

## Out of scope

- Attachments, HTML composition, custom headers (so true In-Reply-To threading is not set; replies are new messages with a Re: subject to the right people, which threads by subject in practice), marking mail read, and mailbox management.

## Design

- Envelope Index facts the SQL relies on: messages.subject and messages.sender are ROWID references into subjects and addresses; messages.mailbox references mailboxes whose url tail names the mailbox; recipients(message_id, address_id, type) carries to (0) and cc (1); messages."read" is the read flag; date_received is Unix seconds.
- search matches subject, sender address, and sender display name with LIKE, optionally filtered to a mailbox by url fragment, newest first.
- thread returns messages of one conversation_id oldest first with to-recipients resolved per message and bodies parsed from .emlx; the thread's participants are the union of senders and recipients.
- The single-walk body loading collects every needed ROWID first, then enumerates the Mail directory once, matching filenames and stopping early when all are found.

## Test plan

MailToolsTests with a fake service, failing first: routing, required arguments, reply resolution (no recipients plus reply_to_message_id resolves the sender and Re: subject; explicit fields win), draft versus send audit copy, JSON round trips, executor wiring for mail.

MailDatabaseTests against a fixture Envelope Index and fixture .emlx files, failing first:

- search joins subjects, addresses, and mailboxes, filters by mailbox, converts Unix dates exactly, and maps the read flag.
- thread orders messages oldest first, resolves to-recipients, parses a multipart quoted-printable .emlx body to its text/plain part, and reads "(body unavailable)" when the file is missing.
- The mailbox display name derives from the url tail.

MailIntegrationTests, gated, Terminal-run with Full Disk Access: search returns plausible rows from the real index; thread fetches one real conversation.

## Acceptance criteria

- All ungated tests above exist, were observed red before implementation (recorded in the commit body), and pass.
- The compose path is raw Apple events only, no osascript, no AppleScript source.
- swift test (ungated) stays green; real-index verification and live compose land with HC-012 through the app identity.
