# HC-008: Messages service

## Why

Messages is the service where the AGENTS.md access hierarchy earns its keep: reads come from chat.db read-only (tier 2), sending goes out as one raw in-process Apple event (tier 3, approval-gated at the gateway), and marking read drives Messages through its own URL scheme so the daemon owns the state change (tier 4, the SIP-safe approach carried over from the previous build). Nothing here ever writes a data store Messages owns.

## Scope

- Domain types: Conversation, MessageHit, SendReceipt, MarkReadResult, ChatTarget.
- MessagesServicing protocol (recent, search, send, markRead) and the MessagesTools translator with audit copy that distinguishes draft (sent after approval) from send.
- Sub-seams so each mechanism is independently fakeable: ChatDatabaseReading (reads and chat targeting), MessageSending, ConversationMarkReading. MessagesService composes them.
- ChatDatabase: an actor over the SQLite C API, opened read-only, implementing recents, search, conversation targeting, and unread counts against the real chat.db schema. Unit-tested ungated against a fixture database built with the same schema.
- TypedStreamText: a heuristic extractor for the attributedBody typedstream blob (marker 0x84 0x01 0x2B, then a 1, 2, or 4 byte length, then UTF-8), used when the text column is null. Real-data verification lands at HC-012; rows where extraction fails read "(rich message)".
- AppleEventMessageSender: one raw Apple event to com.apple.MobileSMS (class icht, id send, direct parameter the text, TO parameter an object specifier for chat by unique id). The chat guid comes from chat.db targeting, so v0.1 sends only into existing conversations; a recipient with no existing chat fails with "Start the conversation in Messages once, then Honeycrisp can reply." Automation denial maps to a System Settings sentence; Messages not running is launched first.
- MessagesMarkReadDriver: 1:1 chats only (groups fail with an explicit unsupported sentence), opens imessage://<handle>, foregrounds Messages, polls the unread count to confirm, then restores the previously frontmost app. Returns marked_read plus confirmed.
- Gated integration test: recent and search against the real chat.db (needs Full Disk Access, Terminal-run).

## Out of scope

- Attachments, tapback sending, group sends to brand-new groups, and contact-name resolution of handles (the model can use contacts tools; a built-in resolver is a future nicety).

## Design

- chat.db facts the SQL relies on: message.date is nanoseconds since 2001-01-01 (Date(timeIntervalSinceReferenceDate:) after dividing by 1e9); style 43 is a group and 45 is 1:1; associated_message_type over 0 marks reactions and item_type over 0 marks system rows, both excluded; unread is is_read = 0 and is_from_me = 0; chat.guid (like iMessage;-;+15551234567) is exactly the scripting chat id the send event targets.
- recent: latest chats by last real message, each with display name (or the participant handles joined), participants, latest preview, from-me flag, timestamp, and unread count.
- search: LIKE over message text (attributedBody is not text-searchable in SQL; extracted rows still surface in recents), optional contact filter over chat identifier, display name, and handle, newest first.
- Sender resolution order for send and markRead: exact 1:1 handle match, then display name match, then chat identifier match.
- The translator requires recipient and body for draft and send, conversation for mark_read, query for search; draft and send both call MessagesServicing.send (the gateway already distinguished their approval), with draft audited as "Drafted a reply to X" and the mock's summary.

## Test plan

MessagesToolsTests with a fake service, failing first: routing, required-argument failures, JSON round trips, the draft and send audit sentences, mark_read copy, and executor wiring for messages.

ChatDatabaseTests against a temp fixture database with the real schema subset (chat, handle, message, chat_message_join, chat_handle_join), failing first:

- recent orders chats by last message, carries previews, from-me flags, unread counts, group naming by display_name and 1:1 naming by handle, and excludes reaction rows from previews.
- A null-text message with a fixture attributedBody in the documented layout surfaces the extracted text.
- search matches text, filters by contact, maps senders (me versus handle), and converts Apple epoch dates exactly.
- conversationTarget resolves by handle and by display name with the right isGroup flag; unreadCount counts only inbound unread.

MessagesIntegrationTests, gated, Terminal-run with Full Disk Access: recent returns plausible conversations from the real chat.db; search runs without error.

## Acceptance criteria

- All ungated tests above exist, were observed red before implementation (recorded in the commit body), and pass.
- The send path compiles as one raw Apple event with no osascript and no AppleScript source anywhere.
- swift test (ungated) stays green; live send, mark read, and real chat.db verification land with HC-012 through the app identity.
