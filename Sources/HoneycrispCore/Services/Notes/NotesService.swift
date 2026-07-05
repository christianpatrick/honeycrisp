import Foundation

/// One note as notes_search sees it.
public struct NoteSummary: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let snippet: String
    public let folder: String
    public let account: String
    public let createdAt: Date?
    public let modifiedAt: Date?
    public let pinned: Bool
    public let locked: Bool
    public let shared: Bool

    public init(
        id: String, title: String, snippet: String, folder: String, account: String,
        createdAt: Date?, modifiedAt: Date?, pinned: Bool, locked: Bool, shared: Bool
    ) {
        self.id = id
        self.title = title
        self.snippet = snippet
        self.folder = folder
        self.account = account
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.pinned = pinned
        self.locked = locked
        self.shared = shared
    }
}

/// One note in full, body as plain text. A locked note carries an empty
/// body and locked true.
public struct NoteDetail: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let body: String
    public let folder: String
    public let account: String
    public let createdAt: Date?
    public let modifiedAt: Date?
    public let pinned: Bool
    public let locked: Bool
    public let shared: Bool

    public init(
        id: String, title: String, body: String, folder: String, account: String,
        createdAt: Date?, modifiedAt: Date?, pinned: Bool, locked: Bool, shared: Bool
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.folder = folder
        self.account = account
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.pinned = pinned
        self.locked = locked
        self.shared = shared
    }
}

/// One folder with its account and live note count.
public struct NoteFolder: Codable, Equatable, Sendable {
    public let name: String
    public let account: String
    public let notes: Int

    public init(name: String, account: String, notes: Int) {
        self.name = name
        self.account = account
        self.notes = notes
    }
}

/// What the Apple event writer needs to address an existing note: the
/// x-coredata bridge id Notes speaks, plus enough to refuse the notes a
/// body rewrite would damage. Replacing a note's body over Apple events
/// drops its embedded attachments, so append refuses attachment carriers.
public struct NoteScriptTarget: Sendable, Equatable {
    public let appleScriptID: String
    public let title: String
    public let locked: Bool
    public let hasAttachments: Bool

    public init(appleScriptID: String, title: String, locked: Bool, hasAttachments: Bool) {
        self.appleScriptID = appleScriptID
        self.title = title
        self.locked = locked
        self.hasAttachments = hasAttachments
    }
}

/// What notes_link reports back: the URL that opens the note on this Mac
/// and on any device signed into the same iCloud account, plus who that
/// account is for share workflows.
public struct NoteLinkResult: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let url: String
    public let accountEmail: String?

    public init(id: String, title: String, url: String, accountEmail: String?) {
        self.id = id
        self.title = title
        self.url = url
        self.accountEmail = accountEmail
    }
}

/// What notes_create reports back. The id and url come from reading the
/// new note back out of the store; when the row is not visible yet they
/// degrade to nil rather than failing a create that already happened.
public struct NoteCreateReceipt: Codable, Equatable, Sendable {
    public let id: String?
    public let url: String?
    public let title: String
    public let folder: String

    public init(id: String?, url: String?, title: String, folder: String) {
        self.id = id
        self.url = url
        self.title = title
        self.folder = folder
    }
}

/// What notes_append reports back.
public struct NoteAppendReceipt: Codable, Equatable, Sendable {
    public let id: String
    public let title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

/// Sub-seam: the write side over Apple events (tier 3).
public protocol NoteWriting: Sendable {
    func create(title: String, body: String?, folder: String?) async throws -> NoteCreateReceipt
    func append(id: String, body: String) async throws -> NoteAppendReceipt
}

/// Sub-seam: read-only access to the Notes store (tier 2 in the AGENTS.md
/// hierarchy).
public protocol NotesDatabaseReading: Sendable {
    func search(
        query: String?, folder: String?, since: Date?, until: Date?, pinnedOnly: Bool, limit: Int
    ) async throws -> [NoteSummary]
    func folders() async throws -> [NoteFolder]
    func note(id: String) async throws -> NoteDetail?
    func scriptTarget(id: String) async throws -> NoteScriptTarget?
    /// Maps a Core Data primary key back to a note, for create receipts.
    func noteByPrimaryKey(_ primaryKey: Int64) async throws -> NoteSummary?
}

/// The Notes domain seam the translator talks to.
public protocol NotesServicing: Sendable {
    func search(
        query: String?, folder: String?, since: Date?, until: Date?, pinnedOnly: Bool, limit: Int
    ) async throws -> [NoteSummary]
    func folders() async throws -> [NoteFolder]
    func note(id: String) async throws -> NoteDetail?
    func link(id: String) async throws -> NoteLinkResult
    func create(title: String, body: String?, folder: String?) async throws -> NoteCreateReceipt
    func append(id: String, body: String) async throws -> NoteAppendReceipt
}

/// The real composition: NoteStore.sqlite for reads, raw Apple events for
/// writes, and the local iCloud account record for link results.
public struct NotesService: NotesServicing {
    private let reader: any NotesDatabaseReading
    private let writer: any NoteWriting
    private let account: any AppleAccountReading

    public init(
        reader: any NotesDatabaseReading,
        writer: any NoteWriting,
        account: any AppleAccountReading
    ) {
        self.reader = reader
        self.writer = writer
        self.account = account
    }

    /// The production wiring.
    public init() {
        let reader = NotesDatabase()
        self.init(
            reader: reader,
            writer: AppleEventNoteWriter(targets: reader),
            account: AppleAccount()
        )
    }

    public func search(
        query: String?, folder: String?, since: Date?, until: Date?, pinnedOnly: Bool, limit: Int
    ) async throws -> [NoteSummary] {
        try await reader.search(
            query: query, folder: folder, since: since, until: until,
            pinnedOnly: pinnedOnly, limit: limit)
    }

    public func folders() async throws -> [NoteFolder] {
        try await reader.folders()
    }

    public func note(id: String) async throws -> NoteDetail? {
        try await reader.note(id: id)
    }

    public func link(id: String) async throws -> NoteLinkResult {
        guard let note = try await reader.note(id: id) else {
            throw ToolFailure("No note matched that id. Use the id notes_search returns.")
        }
        return NoteLinkResult(
            id: note.id,
            title: note.title,
            url: NoteLink.url(for: note.id),
            accountEmail: account.primaryEmail()
        )
    }

    public func create(title: String, body: String?, folder: String?) async throws
        -> NoteCreateReceipt
    {
        try await writer.create(title: title, body: body, folder: folder)
    }

    public func append(id: String, body: String) async throws -> NoteAppendReceipt {
        try await writer.append(id: id, body: body)
    }
}
