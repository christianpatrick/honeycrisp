# HC-006: Contacts service

## Why

Contacts is the simplest of the four apps and establishes the pattern every service follows: a domain protocol the rest of the system fakes, a translator that turns tool arguments into service calls and service results into JSON plus audit copy, a real implementation on the native framework, and a router (ServiceExecutor) that the gateway calls. Per AGENTS.md, Contacts uses tier 1 access: the Contacts framework for reads and writes both, no Apple events anywhere.

## Scope

- Domain types: Contact (id, given and family name, full name, organization, labeled phones and emails) and NewContact.
- ContactsServicing protocol: lookup(query:limit:), contact(id:name:), create(_:).
- ContactsTools translator: routes the three catalog actions, validates arguments with full-sentence failures, encodes snake_case JSON, and writes the audit sentences.
- ServiceExecutor: the ToolExecutor router the gateway uses. Apps without a wired service throw a clear ToolFailure until their task lands.
- ToolJSON: the shared encoder (snake_case keys, ISO 8601 dates, sorted keys).
- CNContactsService: the real implementation over CNContactStore, surfacing missing TCC access as a sentence that points at System Settings.
- Gated integration test: create, lookup, read fields, then delete a uniquely named test contact against the real store.

## Out of scope

- The other three services, UI, and permission prompts (the app owns TCC UX in HC-011).

## Design

- lookup picks its predicate by query shape: an @ means email, mostly digits means phone number, anything else matches names. Limit comes from the argument or config defaultLimit.
- contact(id:name:) prefers the id; a name falls back to the first lookup match; no match is a ToolFailure naming the query.
- create requires a given name (schema-required, revalidated) and accepts family name, phone, email, and organization.
- JSON is snake_case so the model sees given_name and labeled phones as {label, value} pairs.
- Audit copy follows the mock's voice: lookups summarize "Read N contact cards. Nothing was modified."; create summarizes "Created one contact."
- The real service maps CNAuthorizationStatus denied or restricted to a ToolFailure telling the user where to grant access, and requests access when undetermined.

## Test plan

ContactsToolsTests with a fake service, failing first:

- lookup passes query and the config default limit, returns JSON that decodes back into the same contacts, and audits "Read 2 contact cards."
- lookup with an explicit limit overrides the default; a missing query is a ToolFailure naming the argument.
- fields by name returns one card; neither id nor name is a ToolFailure; a no-match from the service surfaces its sentence.
- create maps every argument onto NewContact and audits the new contact's name.
- An unknown contacts action is a ToolFailure.
- ServiceExecutor routes contacts actions to the translator and throws a clear failure for apps that are not wired yet.

ContactsIntegrationTests, gated behind HONEYCRISP_INTEGRATION=1, running against the real CNContactStore:

- Round trip: create a contact named Honeycrisp Test-<uuid>, look it up, read its fields by name, and delete it in cleanup.

## Acceptance criteria

- All unit tests above exist, were observed red before implementation (recorded in the commit body), and pass.
- The integration round trip passes when run from a TCC-capable terminal. The development harness cannot present permission prompts at all, so the authoritative real-data pass lands with HC-012's app-identity verification.
- swift test (ungated) stays green and fast.
