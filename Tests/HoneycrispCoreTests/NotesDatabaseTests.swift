import Compression
import Foundation
import SQLite3
import Testing

@testable import HoneycrispCore

// MARK: - Fixture blobs

/// Raw deflate bytes, the payload inside both containers.
private func rawDeflate(_ payload: Data) -> Data {
    let source = [UInt8](payload)
    var destination = [UInt8](repeating: 0, count: source.count + 512)
    let written = compression_encode_buffer(
        &destination, destination.count, source, source.count, nil, COMPRESSION_ZLIB)
    return Data(destination[0..<written])
}

private func varint(_ value: Int) -> Data {
    var value = UInt64(value)
    var bytes = Data()
    repeat {
        var byte = UInt8(value & 0x7F)
        value >>= 7
        if value != 0 { byte |= 0x80 }
        bytes.append(byte)
    } while value != 0
    return bytes
}

private func lengthDelimited(field: Int, _ payload: Data) -> Data {
    var out = Data(varint(field << 3 | 2))
    out.append(varint(payload.count))
    out.append(payload)
    return out
}

/// The note text at protobuf path 2 (document), 3 (note), 2 (note text),
/// with a stray varint field alongside to make the walker skip.
private func noteProtobuf(_ text: String) -> Data {
    var note = Data([0x08, 0x05])  // field 1, varint, skipped
    note.append(lengthDelimited(field: 2, Data(text.utf8)))
    let document = lengthDelimited(field: 3, note)
    return lengthDelimited(field: 2, document)
}

/// A gzip container with the FNAME flag set, like real NoteStore blobs.
private func gzipped(_ payload: Data) -> Data {
    var out = Data([0x1F, 0x8B, 0x08, 0x08, 0, 0, 0, 0, 0, 0x03])
    out.append(Data("fixture".utf8))
    out.append(0)
    out.append(rawDeflate(payload))
    out.append(Data(repeating: 0, count: 8))
    return out
}

private func zlibWrapped(_ payload: Data) -> Data {
    var out = Data([0x78, 0x9C])
    out.append(rawDeflate(payload))
    out.append(Data(repeating: 0, count: 4))
    return out
}

// MARK: - Fixture store

/// Builds a temp database with the NoteStore.sqlite shape the reader
/// probes: Z_PRIMARYKEY entities, Z_METADATA store UUID, suffixed Core
/// Data columns, and compressed protobuf body blobs.
private func makeFixture() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("honeycrisp-notes-tests-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("NoteStore.sqlite")
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

    var db: OpaquePointer?
    guard sqlite3_open(url.path, &db) == SQLITE_OK else {
        throw ToolFailure("could not create the fixture database")
    }
    defer { sqlite3_close(db) }

    let grocery = gzipped(noteProtobuf("Grocery list\nmilk and eggs\n\u{FFFC}"))
    let tarte = zlibWrapped(noteProtobuf("Tarte tatin\nPeel the apples."))
    let locked = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x42])
    func hex(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined()
    }

    let statements = """
        CREATE TABLE Z_PRIMARYKEY (Z_ENT INTEGER PRIMARY KEY, Z_NAME TEXT, Z_SUPER INTEGER, Z_MAX INTEGER);
        CREATE TABLE Z_METADATA (Z_VERSION INTEGER PRIMARY KEY, Z_UUID TEXT, Z_PLIST BLOB);
        CREATE TABLE ZICCLOUDSYNCINGOBJECT (
            Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER,
            ZTITLE1 TEXT, ZTITLE2 TEXT, ZSNIPPET TEXT, ZIDENTIFIER TEXT,
            ZFOLDER INTEGER, ZACCOUNT4 INTEGER, ZNAME TEXT, ZNOTE INTEGER,
            ZCREATIONDATE1 REAL, ZMODIFICATIONDATE1 REAL, ZFOLDERTYPE INTEGER,
            ZISPINNED INTEGER DEFAULT 0, ZISPASSWORDPROTECTED INTEGER DEFAULT 0,
            ZMARKEDFORDELETION INTEGER DEFAULT 0,
            ZNOTEDATA INTEGER, ZSERVERSHAREDATA BLOB
        );
        CREATE TABLE ZICNOTEDATA (Z_PK INTEGER PRIMARY KEY, ZNOTE INTEGER, ZDATA BLOB);

        INSERT INTO Z_PRIMARYKEY VALUES (1, 'ICCloudSyncingObject', 0, 0);
        INSERT INTO Z_PRIMARYKEY VALUES (7, 'ICAccount', 1, 0);
        INSERT INTO Z_PRIMARYKEY VALUES (12, 'ICFolder', 1, 0);
        INSERT INTO Z_PRIMARYKEY VALUES (17, 'ICNote', 1, 0);
        INSERT INTO Z_PRIMARYKEY VALUES (21, 'ICNoteHidden', 17, 0);
        INSERT INTO Z_PRIMARYKEY VALUES (25, 'ICAttachment', 1, 0);

        INSERT INTO Z_METADATA VALUES (1, 'B0DA7D4B-0000-4000-8000-FIXTURESTORE', NULL);

        INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, Z_ENT, ZNAME, ZIDENTIFIER)
            VALUES (1, 7, 'iCloud', 'ACCOUNT-UUID-1');

        INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, Z_ENT, ZTITLE2, ZIDENTIFIER, ZACCOUNT4, ZFOLDERTYPE)
            VALUES (10, 12, 'Notes', 'DefaultFolder-CloudKit', 1, 0),
                   (11, 12, 'Recipes', 'RECIPES-UUID', 1, 0),
                   (12, 12, 'Recently Deleted', 'TrashFolder-CloudKit', 1, 1),
                   (13, 12, 'All Pinned', 'SMART-UUID', 1, 3);

        INSERT INTO ZICCLOUDSYNCINGOBJECT (
            Z_PK, Z_ENT, ZTITLE1, ZSNIPPET, ZIDENTIFIER, ZFOLDER,
            ZCREATIONDATE1, ZMODIFICATIONDATE1, ZISPINNED,
            ZISPASSWORDPROTECTED, ZMARKEDFORDELETION, ZNOTEDATA)
        VALUES
            (100, 17, 'Grocery list', 'milk and eggs', 'AAAAAAAA-1111-2222-3333-444444444444', 10,
             800000000, 800000300, 1, 0, 0, 1),
            (102, 17, 'Locked secrets', NULL, 'CCCCCCCC-1111-2222-3333-444444444444', 10,
             800000000, 800000100, 0, 1, 0, 3),
            (103, 17, 'Old trashed', NULL, 'DDDDDDDD-1111-2222-3333-444444444444', 12,
             800000000, 800000050, 0, 0, 0, NULL),
            (104, 17, 'Ghost', NULL, 'EEEEEEEE-1111-2222-3333-444444444444', 10,
             800000000, 800000040, 0, 0, 1, NULL),
            (105, 21, 'Sub note', 'a subentity row', 'FFFFFFFF-1111-2222-3333-444444444444', 11,
             800000000, 800000010, 0, 0, 0, NULL);

        INSERT INTO ZICCLOUDSYNCINGOBJECT (
            Z_PK, Z_ENT, ZTITLE1, ZSNIPPET, ZIDENTIFIER, ZFOLDER,
            ZCREATIONDATE1, ZMODIFICATIONDATE1, ZNOTEDATA, ZSERVERSHAREDATA)
        VALUES
            (101, 17, 'Tarte tatin', 'butter, apples', 'BBBBBBBB-1111-2222-3333-444444444444', 11,
             800000000, 800000200, 2, X'01');

        INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, Z_ENT, ZIDENTIFIER, ZNOTE)
            VALUES (200, 25, 'ATTACHMENT-UUID', 100);

        INSERT INTO ZICNOTEDATA VALUES (1, 100, X'\(hex(grocery))');
        INSERT INTO ZICNOTEDATA VALUES (2, 101, X'\(hex(tarte))');
        INSERT INTO ZICNOTEDATA VALUES (3, 102, X'\(hex(locked))');
        """
    guard sqlite3_exec(db, statements, nil, nil, nil) == SQLITE_OK else {
        let message = String(cString: sqlite3_errmsg(db))
        throw ToolFailure("fixture SQL failed: \(message)")
    }
    return url
}

// MARK: - Reader

@Suite("Notes database")
struct NotesDatabaseTests {
    @Test("no filters returns live notes latest-first with mapped fields")
    func unfiltered() async throws {
        let database = NotesDatabase(path: try makeFixture().path)
        let notes = try await database.search(
            query: nil, folder: nil, since: nil, until: nil, pinnedOnly: false, limit: 10)
        #expect(notes.map(\.title) == ["Grocery list", "Tarte tatin", "Locked secrets", "Sub note"])

        let grocery = try #require(notes.first)
        #expect(grocery.id == "AAAAAAAA-1111-2222-3333-444444444444")
        #expect(grocery.snippet == "milk and eggs")
        #expect(grocery.folder == "Notes")
        #expect(grocery.account == "iCloud")
        #expect(grocery.pinned)
        #expect(grocery.locked == false)
        #expect(grocery.shared == false)
        #expect(grocery.modifiedAt == Date(timeIntervalSinceReferenceDate: 800_000_300))
        #expect(grocery.createdAt == Date(timeIntervalSinceReferenceDate: 800_000_000))

        let tarte = notes[1]
        #expect(tarte.shared)
        let lockedNote = notes[2]
        #expect(lockedNote.locked)
    }

    @Test("query matches titles and snippets")
    func queryFilter() async throws {
        let database = NotesDatabase(path: try makeFixture().path)
        let byTitle = try await database.search(
            query: "tarte", folder: nil, since: nil, until: nil, pinnedOnly: false, limit: 10)
        #expect(byTitle.map(\.title) == ["Tarte tatin"])

        let bySnippet = try await database.search(
            query: "milk", folder: nil, since: nil, until: nil, pinnedOnly: false, limit: 10)
        #expect(bySnippet.map(\.title) == ["Grocery list"])
    }

    @Test("the folder filter narrows to one folder")
    func folderFilter() async throws {
        let database = NotesDatabase(path: try makeFixture().path)
        let recipes = try await database.search(
            query: nil, folder: "Recipes", since: nil, until: nil, pinnedOnly: false, limit: 10)
        #expect(recipes.map(\.title) == ["Tarte tatin", "Sub note"])
    }

    @Test("since and until bound the modification window")
    func timeWindow() async throws {
        let database = NotesDatabase(path: try makeFixture().path)
        let since = Date(timeIntervalSinceReferenceDate: 800_000_150)
        let until = Date(timeIntervalSinceReferenceDate: 800_000_250)
        let hits = try await database.search(
            query: nil, folder: nil, since: since, until: until, pinnedOnly: false, limit: 10)
        #expect(hits.map(\.title) == ["Tarte tatin"])
    }

    @Test("pinned only returns pinned notes")
    func pinnedFilter() async throws {
        let database = NotesDatabase(path: try makeFixture().path)
        let pinned = try await database.search(
            query: nil, folder: nil, since: nil, until: nil, pinnedOnly: true, limit: 10)
        #expect(pinned.map(\.title) == ["Grocery list"])
    }

    @Test("reading a note extracts the compressed body, gzip and zlib both")
    func bodies() async throws {
        let database = NotesDatabase(path: try makeFixture().path)
        let grocery = try #require(
            try await database.note(id: "AAAAAAAA-1111-2222-3333-444444444444"))
        #expect(grocery.body == "Grocery list\nmilk and eggs\n[attachment]")
        #expect(grocery.title == "Grocery list")

        let tarte = try #require(
            try await database.note(id: "bbbbbbbb-1111-2222-3333-444444444444"))
        #expect(tarte.body == "Tarte tatin\nPeel the apples.")
    }

    @Test("a locked note lists but carries no body text")
    func lockedNote() async throws {
        let database = NotesDatabase(path: try makeFixture().path)
        let locked = try #require(
            try await database.note(id: "CCCCCCCC-1111-2222-3333-444444444444"))
        #expect(locked.locked)
        #expect(locked.body.isEmpty)
    }

    @Test("an unknown id reads as nil")
    func unknownNote() async throws {
        let database = NotesDatabase(path: try makeFixture().path)
        let missing = try await database.note(id: "99999999-0000-0000-0000-000000000000")
        #expect(missing == nil)
    }

    @Test("folders list names, accounts, and live note counts, without trash or smart folders")
    func folders() async throws {
        let database = NotesDatabase(path: try makeFixture().path)
        let folders = try await database.folders()
        #expect(folders.map(\.name) == ["Notes", "Recipes"])
        #expect(folders.map(\.account) == ["iCloud", "iCloud"])
        #expect(folders.map(\.notes) == [2, 2])
    }

    @Test("the script target maps a UUID to the x-coredata bridge id and flags attachments")
    func scriptTarget() async throws {
        let database = NotesDatabase(path: try makeFixture().path)
        let target = try #require(
            try await database.scriptTarget(id: "AAAAAAAA-1111-2222-3333-444444444444"))
        #expect(
            target.appleScriptID
                == "x-coredata://B0DA7D4B-0000-4000-8000-FIXTURESTORE/ICNote/p100")
        #expect(target.title == "Grocery list")
        #expect(target.locked == false)
        #expect(target.hasAttachments)

        let locked = try #require(
            try await database.scriptTarget(id: "CCCCCCCC-1111-2222-3333-444444444444"))
        #expect(locked.locked)
        #expect(locked.hasAttachments == false)
    }

    @Test("a primary key maps back to the note summary for create receipts")
    func primaryKeyLookup() async throws {
        let database = NotesDatabase(path: try makeFixture().path)
        let note = try #require(try await database.noteByPrimaryKey(101))
        #expect(note.id == "BBBBBBBB-1111-2222-3333-444444444444")
        #expect(note.title == "Tarte tatin")
    }

    @Test("a missing database fails with the Full Disk Access sentence")
    func missingDatabase() async {
        let database = NotesDatabase(path: "/nonexistent/honeycrisp/NoteStore.sqlite")
        do {
            _ = try await database.search(
                query: nil, folder: nil, since: nil, until: nil, pinnedOnly: false, limit: 5)
            Issue.record("expected a ToolFailure")
        } catch let failure as ToolFailure {
            #expect(failure.message.contains("Full Disk Access"))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }
}

// MARK: - Body extraction

@Suite("Note body extraction")
struct NoteBodyTests {
    @Test("a gzip blob with a filename decodes to the note text")
    func gzipBody() {
        let blob = gzipped(noteProtobuf("Hello\nWorld"))
        #expect(NoteBody.text(from: blob) == "Hello\nWorld")
    }

    @Test("a bare zlib blob decodes too")
    func zlibBody() {
        let blob = zlibWrapped(Data("Ciao".utf8))
        #expect(NoteBody.inflate(blob) == Data("Ciao".utf8))
    }

    @Test("attachment placeholders read as markers")
    func attachmentMarker() {
        let blob = gzipped(noteProtobuf("Photo:\n\u{FFFC}\ndone"))
        #expect(NoteBody.text(from: blob) == "Photo:\n[attachment]\ndone")
    }

    @Test("garbage and protobufs without the text field degrade to nil")
    func malformed() {
        #expect(NoteBody.text(from: Data([0xDE, 0xAD, 0xBE, 0xEF])) == nil)
        let wrongPath = gzipped(lengthDelimited(field: 5, Data("nope".utf8)))
        #expect(NoteBody.text(from: wrongPath) == nil)
        #expect(NoteBody.text(from: Data()) == nil)
    }
}
