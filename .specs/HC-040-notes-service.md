# HC-040: Notes service

## Why

A user request: connect Apple Notes as the sixth app, with the full set of operations that make sense over MCP. The request that shaped the design is note links: an assistant should be able to copy a link to a note so another app, like Apple Reminders, can hold a link back to it.

The request assumed a link requires sharing the note with an Apple ID email address. Investigation found a simpler path: Notes has its own URL scheme, `applenotes:note/<uuid>`, the same URLs Notes writes for its note-to-note links, and the Notes scripting dictionary ships an `open note location` command that consumes them. Those links open the note directly on this Mac and on any device signed into the same iCloud account, no sharing step needed. Sharing a note to icloud.com (CloudKit collaboration) has no scriptable path at all: no framework, no Apple event, only the share sheet, which we do not drive. So the link tool returns the URL scheme link, and it also reports the signed-in iCloud account email (from MobileMeAccounts.plist) so a client that wants the manual icloud.com share flow knows the address involved.

## Scope

- The `notes` app in AppID, the action catalog, config, permission engine, panel UI, and onboarding.
- Five catalog actions: `search`, `read`, and `link` (reads), `create` and `append` (writes). One registry alias, `notes_folders`, riding `notes.search`.
- `NotesDatabase`: read-only SQLite access to NoteStore.sqlite (tier 2), with the entity and column layout probed at runtime, and note text extracted from the gzipped protobuf body blobs.
- `NoteLinkBuilder` and `AppleAccount`: the `applenotes:` URL and the signed-in iCloud account email.
- `AppleEventNoteWriter`: create note and append to note as raw in-process Apple events (tier 3).
- The Notes app icon, docs, and the spec index.

## Out of scope

- Deleting, moving, or renaming notes and folders, and replacing an existing note's body. Append is the one mutation of existing content; nothing destructive ships in this task.
- Creating folders. `notes_create` targets an existing folder or the default one.
- Full-text search across note bodies. Search matches titles and snippets in SQL; `notes_read` returns the full text of one note. Sweeping every body blob per search does not scale and silent caps lie.
- icloud.com collaboration links, for the reason in Why.
- Password-protected note contents. Locked notes list with `locked: true` and no body text; append refuses them.
- Attachments. They appear in note text as `[attachment]` markers only.

## Design

### Catalog

App descriptor: `Notes`, blurb "Search, read, and capture notes." Actions, following the read-on write-off convention:

| Action | Label | Kind | defaultOn | requiresApproval |
| --- | --- | --- | --- | --- |
| search | Search notes | read | true | false |
| read | Read a note | read | true | false |
| link | Copy a note link | read | true | false |
| create | Create a note | write | false | false |
| append | Append to a note | write | false | false |

Nothing here leaves the Mac, so no action requires approval; the AGENTS.md sentence "requiresApproval actions are mail.send and messages.send" stays true. The catalog grows to twenty-five actions across six apps.

### Tools

- `notes_search`: filters compose like mail_search: `query` (title and snippet words), `folder`, `since`/`until` (modification time), `pinned_only`, `limit`; no filters returns the latest notes. Summaries carry `id` (the note's UUID), `title`, `snippet`, `folder`, `account`, `modified_at`, `created_at`, `pinned`, `locked`, `shared`.
- `notes_folders` (alias, executes `folders` on the `notes.search` switch): folder names with account and live note counts.
- `notes_read`: one note in full by id: the summary fields plus `body` as plain text. A locked note returns `locked: true` and an empty body.
- `notes_link`: `id`, `title`, `url` (`applenotes:note/<uuid>`), and `account_email`, the iCloud account signed into this Mac (null when none is). The description tells the model the URL opens the note on any of the user's own devices and can be pasted into a reminder.
- `notes_create`: `title` required, `body` and `folder` optional. Creates via Apple events, then reads the new note's identity back so the receipt carries `id` and `url` alongside `title` and `folder`; a client can link a note it just created without a second call. When the row is not yet visible in the store, id and url degrade to null rather than failing the create.
- `notes_append`: `id` and `body` required. Appends paragraphs to the end of the note. Locked notes refuse with a sentence.

### Reads: NotesDatabase (tier 2)

- Path: `~/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite`, opened SQLITE_OPEN_READONLY with the Full Disk Access failure sentence, exactly like chat.db and the Envelope Index.
- Core Data's layout drifts across macOS versions (suffixed columns like ZTITLE1), so nothing is hardcoded that can be probed, following the HC-019 precedent:
  - Entity discriminators come from `Z_PRIMARYKEY`: the `Z_ENT` values for `ICNote`, `ICFolder`, and `ICAccount` rows (subentities included, matched by range where present).
  - Columns come from `PRAGMA table_info(ZICCLOUDSYNCINGOBJECT)` with preference orders: note title `ZTITLE1`, folder title `ZTITLE2`, snippet `ZSNIPPET`, dates `ZMODIFICATIONDATE1` and `ZCREATIONDATE3` falling back through their suffix families, `ZISPINNED`, `ZISPASSWORDPROTECTED`, `ZMARKEDFORDELETION`, `ZFOLDER`, `ZACCOUNT` family for the folder's account, `ZIDENTIFIER`, `ZNOTEDATA`.
- Live notes only: `ZMARKEDFORDELETION` clear on the note and on its folder, and the folder is not the trash folder (probed folder type column when present).
- Dates are Core Data seconds since 2001-01-01.
- Note text: `ZICNOTEDATA.ZDATA` is a compressed protobuf. The reader detects the container by magic bytes (gzip `1F 8B` with header fields parsed and skipped, or a bare zlib stream) and inflates with the Compression framework. In the protobuf, the plain text is the string at field path 2 (document) then 3 (note) then 2 (note text), read with a minimal hand-rolled varint and length-delimited walker. U+FFFC attachment placeholders render as `[attachment]`. Anything unrecognized degrades to a `(note text unavailable)` body instead of failing the read.
- The AppleScript bridge id for a note is `x-coredata://<store uuid>/ICNote/p<Z_PK>`; the store uuid is `Z_METADATA.Z_UUID`. The reader exposes this mapping so the writer can address existing notes by the same UUID the tools speak.

### Links and the Apple ID

- `applenotes:note/<uuid>` with the uuid exactly as stored (uppercase). Constructing it is pure string work from `ZIDENTIFIER`.
- The signed-in iCloud account email is `Accounts[0].AccountID` in `~/Library/Preferences/MobileMeAccounts.plist`, read with PropertyListSerialization, path injectable for tests, nil when absent. Reading that plist needs no TCC grant (verified on this machine).

### Writes: AppleEventNoteWriter (tier 3)

Raw in-process Apple events to `com.apple.Notes`, codes straight from Notes.sdef: class `note` with `body` (settable, HTML), `pnam`, read-only `ID  `; folder `cfol`; account `acct`; app properties `dfac` (default account) and account property `dfol` (default folder). No osascript, no AppleScript source. Launch-if-needed, procNotFound retry, and the -1743 Automation sentence follow AppleEventMessageSender.

- Create: `core`/`crel` with `kocl` note, `prdt` `{body: <html>}`, and `insh` at end of the target folder: the named folder of the default account when `folder` is given, otherwise the default account's default folder. The reply's object specifier carries the new note's `x-coredata://` id; its `p<Z_PK>` resolves through the reader to the UUID for the receipt.
- Append: get `body` of `note id <x-coredata id>`, then set it to the old HTML plus the new paragraphs. Two events, `core`/`getd` and `core`/`setd`.
- HTML: the title becomes an `<h1>` first block (Notes derives the note name from it), body lines become `<div>` blocks, blank lines `<div><br></div>`, with `&`, `<`, `>` escaped. Pure functions, unit tested.

### Permissions and macOS grants

Reads need Full Disk Access, which the onboarding's Notes row explains (same grant Mail and Messages already use). Writes prompt once for Automation of Notes under the existing `com.apple.security.automation.apple-events` entitlement and NSAppleEventsUsageDescription. No new hardened runtime entitlement: Notes has no framework TCC prompt, so HC-037's file is already complete.

## Test plan

Failing tests first, fixture-driven, no TCC in unit tests:

- ActionCatalogTests: twenty-five actions across six apps, notes rows spot-checked, approval set still exactly mail.send and messages.send.
- NotesDatabaseTests against a fixture NoteStore built in the test (Z_PRIMARYKEY, Z_METADATA, ZICCLOUDSYNCINGOBJECT, ZICNOTEDATA, with real gzip and zlib compressed protobuf blobs): latest-first no-filter search, query matching title and snippet, folder and time and pinned filters, trashed exclusion, locked listing, full body read with attachment markers, folders with counts and account names, UUID to x-coredata id mapping, the Full Disk Access sentence on a missing file.
- NoteBodyExtractorTests: gzip header variants (FNAME, FEXTRA), bare zlib, malformed protobuf degrading to nil, U+FFFC replacement.
- NoteLinkTests: URL construction and the account email from a fixture plist, nil without one.
- NotesHTMLTests: escaping, paragraph splitting, empty and title-only bodies.
- NotesToolsTests with a fake service: JSON output and audit copy per action, argument validation sentences (missing id, missing title, missing body, unparseable dates), the locked-note refusal.
- Registry and gateway: notes tools listed at read level minus the writes, notes_folders rides the notes.search switch and audits as folders.
- Integration, gated behind HONEYCRISP_INTEGRATION=1 on this machine: the real NoteStore opens and lists notes with well-formed UUIDs and links; create writes a real note through Apple events, append extends it, and the test deletes it again with a direct `delo` event so the library stays clean (delete stays out of the shipped toolset).

## Acceptance criteria

- `swift build` and `swift test` pass with the new suites.
- The catalog holds twenty-five actions across six apps and only the two sends require approval.
- notes_search, notes_folders, notes_read, and notes_link work against a fixture store, and against the real store under the integration flag.
- notes_link returns `applenotes:note/<uuid>` plus the signed-in account email on this Mac.
- notes_create and notes_append change real notes through Apple events under the integration flag, and notes_create's receipt links the new note.
- The panel, onboarding, and packaging show Notes with its icon; AGENTS.md and README name six apps; the spec index records HC-040.
