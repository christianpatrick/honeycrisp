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
