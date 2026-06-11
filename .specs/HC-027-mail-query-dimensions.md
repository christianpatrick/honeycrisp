# HC-027: Mail query dimensions

## Why

mail_search required a keyword, so "unread mail since yesterday" and "mail from Alex this week" were inexpressible; the audit log even caught a client searching for the literal keyword "unread". The Envelope Index answers every one of these with where clauses.

## Scope

- mail_search goes filters-first: query becomes optional, and from, to, since, until, and unread_only compose with it and with mailbox. No filters at all means the latest mail, which makes search the browse tool too. The query matches the envelope (subject, sender) as before; bodies are not text-searchable without our own index, which stays future work.
- mail_mailboxes, a new tool listing mailbox display names, introduced with the registry alias mechanism: a tool that rides an existing catalog action's permission switch (here mail.search) instead of adding a user-facing row. RegisteredTool gains an executionAction distinct from its permission descriptor; the gateway authorizes on the descriptor and executes the executionAction, which also lands in the audit entry as what actually ran.
- The to filter resolves through the HC-019 probed recipients schema and matches any recipient (to or cc); when the schema is unusable it fails with a sentence instead of silently ignoring the filter.

## Test plan

Failing first: fixture tests for no-filter browse (newest first), from, to (per recipients schema), since/until (Unix seconds), unread_only, and mailboxes() returning the decoded display names; translator tests for pass-through, the browse case, and mailboxes routing and audit copy; the gateway default listing grows to fifteen.

## Acceptance criteria

- All new tests observed red, then green; the suite stays green.
- Live: mail_search with unread_only and since returns real rows with no keyword.
