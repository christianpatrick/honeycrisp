# HC-025: Remove the misleading messages_draft action

## Why

iMessage has no draft concept. The HC-008 catalog carried messages.draft as "compose, then send after approval", but both messages_draft and messages_send call the same send(), so drafting just sends, under a name that implies it does not. Christian confirmed there is no real draft and asked to remove it. A tool whose name lies about its effect is worse than no tool.

## Scope

- Drop the messages.draft action from the catalog. Messages goes from five actions to four, the catalog from twenty to nineteen, and the approval set from three to two (mail.send, messages.send).
- Remove the messages_draft tool definition, the draft routing and the asDraft branch in MessagesTools (send keeps only the real send path), and update the Messages app blurb from "draft replies" to "send replies" so it is honest.
- AGENTS.md: update the action count, the requiresApproval list, and the "writes whose effect leaves the Mac" wording (no more "the Messages draft that sends after approval").
- Old configs heal through normalization: a stale messages.draft switch is dropped on load, and the decision for action "draft" becomes denied(unknownAction).
- Version 0.2.2, repackage, relaunch, confirm tools/list no longer offers messages_draft.

## Test plan

Failing first: ActionCatalogTests counts move to nineteen total and four for Messages, and the approval set becomes {mail.send, messages.send}. MessagesToolsTests drops the draft test and asserts that action "draft" now throws Messages-cannot-do; send still works and keeps its audit copy.

## Acceptance criteria

- The catalog and approval-set tests were observed red and pass; the suite stays green.
- messages_draft is gone from the live tools/list; messages_send still sends after approval.
- v0.2.2 packaged, running, tagged.
