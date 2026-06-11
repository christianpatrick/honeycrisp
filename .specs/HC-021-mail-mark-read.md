# HC-021: Mark mail as read

- Task number: HC-021 (no GitHub issue yet)
- Status: done
- Date: 2026-06-09

## Why

Triage is the natural follow-up to "summarize my unread mail": once the assistant has read a thread back to you, marking it read closes the loop. Christian asked for it after the first real Mail sessions.

## Scope

- A seventeenth catalog action: mail.mark_read, "Mark as read", kind write, default off, no per-use approval. It changes your own mailbox state (Mail syncs the flag to your server), the same class as messages.mark_read, so it is a deliberate enable rather than an ask-every-time.
- Tool mail_mark_read taking message_id (from mail_search or mail_read) or thread_id (marks every message in the conversation); exactly one is required.
- Mechanism, per the AGENTS.md hierarchy: we never write Mail's store, so this is one raw in-process Apple event per message: core/setd on the read status property (isrd) of the inbox message (mssg under the application's inmb property) matched by a whose-id test clause. Mail updates its own database and syncs upstream. No osascript, no AppleScript source.
- Scope honesty: v1 matches messages in inboxes, which is where triage happens; a message filed elsewhere fails with a sentence saying so. Mail not running is launched quietly first; Automation denial maps to the System Settings sentence.
- MailServicing grows markRead(messageIDs:) returning the count, routed to a new MailReadMarking seam (AppleEventMailReadMarker in production); the translator resolves thread_id to message ids through the existing thread call.
- README's Mail row mentions marking read; AGENTS.md's action count updates to seventeen.
- Version 0.1.8, repackage, relaunch, and verify live by marking a real unread message read and re-searching to see the flag flip.

## Test plan

Failing first: ActionCatalogTests counts move to 17 total and 5 for Mail with a spot check of the new descriptor; MailToolsTests cover the message_id pass-through, thread_id resolving to every message id via the fake's thread, the one-of-two argument validation, and the audit copy. The Apple event itself is verified live through the running app (the same standard as send), since only Mail can judge the descriptor.

## Acceptance criteria

- Catalog and translator tests were observed red and pass; the suite stays green.
- A real unread message flips to read on this Mac through a real MCP client, confirmed by a follow-up search.
- v0.1.8 packaged, running, tagged.
