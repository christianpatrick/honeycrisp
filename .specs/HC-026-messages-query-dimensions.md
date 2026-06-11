# HC-026: Messages query dimensions

## Why

Christian's audit of the tool surface: the reads are keyword-gated when keywords should be one filter among several. "What did April and I talk about this week" is inexpressible today, since messages_search requires a query and messages_recent returns one preview per conversation. chat.db answers all of these trivially.

## Scope

- messages_history, a new tool and a new catalog action (messages.history, "Read a conversation", read, on by default): the transcript with one conversation, chronological, args conversation (required), since (ISO 8601), limit (most recent N within the window).
- messages_search: query becomes optional whenever contact, since, or until is present; since/until bound the match window. No filters at all is still an error here (that is what recent and history are for).
- messages_recent: since (only conversations whose last message is on or after it) and unread_only (only conversations with inbound unread).
- A shared date-argument helper so every since/until/from/to parse failure reads the same ISO 8601 sentence.

## Design

- ChatDatabaseReading grows history(conversation:since:limit:) and the search and recent signatures gain the new parameters; MessagesServicing mirrors them. History resolves the conversation through the existing targeting (handle, then display name), takes the most recent N rows in the window, and returns them oldest first, the natural transcript order, reusing MessageHit.
- SQL: since/until compare against chat.db's nanosecond epoch; unread_only is an EXISTS over inbound unread rows per chat.
- Catalog: twenty actions; Messages back to five. The gateway's default visible set grows by one.

## Test plan

Failing first: catalog counts and the messages.history spot check; fixture SQL tests for history (resolves by name, respects since, chronological, limit keeps the newest), search with contact-only and since/until and no keyword, recent with unread_only and since; translator tests for argument validation (history needs conversation; search needs at least one filter) and audit copy.

## Acceptance criteria

- All new tests observed red, then green; the suite stays green.
- Live: messages_history returns a real conversation transcript through the running app.
