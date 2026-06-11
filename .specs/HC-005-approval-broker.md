# HC-005: Approval broker

## Why

The design's approval moment: when the assistant asks to do something whose effect leaves the Mac, Honeycrisp does not act silently. The gateway already classifies those calls as needsApproval; this task is the piece that suspends the tool call, surfaces the request to the user, and resumes it with their answer. HC-011 attaches the actual notification UI; the broker is the engine underneath, designed so the UI is a dumb presenter.

## Scope

- ApprovalBroker, an actor implementing the HC-004 ApprovalRequesting seam: requestApproval suspends the caller until the user resolves it or it times out.
- A pending-request surface: an onRequest handler the app uses to post the notification, a pending() listing, and resolve(id:approved:) for the notification's Allow once and Don't allow buttons.
- Timeout behavior: deny by default, default 120 seconds, configurable.

## Out of scope

- The UNUserNotification presentation (HC-011), and anything about how denials read to the model (HC-004 owns the copy).

## Design

- Each request gets a UUID and a PendingApproval (id, prompt, requestedAt). The continuation is stored, the handler fires, and a timeout task starts, all atomically inside the actor before the caller suspends, so a resolve arriving immediately after the handler fires always finds the continuation.
- resolve(id:approved:) resumes the caller, cancels the timeout task, and removes the pending entry. Unknown ids and second resolutions are no-ops, so a late timeout racing a user tap is harmless either way.
- Timeout resolves as denied. The gateway then audits it as denied; the user seeing the stale notification later and tapping Allow once hits the unknown-id no-op.
- Concurrent requests are independent: two pending approvals resolve by their own ids in any order.

## Test plan

ApprovalBrokerTests, failing first, using an AsyncStream fed by the onRequest handler so nothing polls or sleeps except the timeout test, where the timeout is the subject:

- Allowing resolves requestApproval true and empties pending().
- Denying resolves false.
- A 50 millisecond timeout with no resolution returns false and empties pending().
- The handler receives the pending approval carrying the original prompt.
- Two concurrent requests resolve independently by id with opposite answers.
- Resolving an unknown id does nothing.
- A second resolve of the same id is a no-op (the first answer stands).

## Acceptance criteria

- All tests above exist, were observed red before implementation (recorded in the commit body), and pass.
- ApprovalBroker conforms to ApprovalRequesting and slots into the gateway unchanged.
- swift test passes on this machine.
