import Foundation
import SQLite3
import Testing
import HoneycrispCore

/// Builds a temp database with the real chat.db schema subset, so the SQL in
/// ChatDatabase is exercised for real without any TCC grant.
private func makeFixture() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("honeycrisp-tests-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("chat.db")
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

    var db: OpaquePointer?
    guard sqlite3_open(url.path, &db) == SQLITE_OK else {
        throw ToolFailure("could not create the fixture database")
    }
    defer { sqlite3_close(db) }

    // Apple epoch nanoseconds, matching modern chat.db rows.
    func ns(_ seconds: Int64) -> Int64 { seconds * 1_000_000_000 }

    let blobText = "see you there"
    var blob = Data([0x04, 0x0B])
    blob.append("streamtyped".data(using: .utf8)!)
    blob.append(Data([0x81, 0xE8, 0x03, 0x84, 0x01, 0x40, 0x84, 0x84, 0x84]))
    blob.append("NSAttributedString".data(using: .utf8)!)
    blob.append(Data([0x00, 0x84, 0x84]))
    blob.append("NSString".data(using: .utf8)!)
    blob.append(Data([0x01, 0x94, 0x84, 0x01, 0x2B]))
    blob.append(Data([UInt8(blobText.utf8.count)]))
    blob.append(blobText.data(using: .utf8)!)
    blob.append(Data([0x86]))
    let blobHex = blob.map { String(format: "%02X", $0) }.joined()

    let statements = """
        CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, guid TEXT, chat_identifier TEXT, display_name TEXT, style INTEGER);
        CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT, service TEXT);
        CREATE TABLE message (ROWID INTEGER PRIMARY KEY, guid TEXT, text TEXT, attributedBody BLOB, handle_id INTEGER DEFAULT 0, is_from_me INTEGER DEFAULT 0, date INTEGER, is_read INTEGER DEFAULT 0, item_type INTEGER DEFAULT 0, associated_message_type INTEGER DEFAULT 0);
        CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER, message_date INTEGER);
        CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);

        INSERT INTO handle VALUES (1, '+15551234567', 'iMessage');
        INSERT INTO handle VALUES (2, 'alex@studio.com', 'iMessage');
        INSERT INTO handle VALUES (3, '+15559990000', 'iMessage');

        INSERT INTO chat VALUES (1, 'iMessage;-;+15551234567', '+15551234567', NULL, 45);
        INSERT INTO chat VALUES (2, 'iMessage;+;chat123', 'chat123', 'Studio friends', 43);

        INSERT INTO chat_handle_join VALUES (1, 1);
        INSERT INTO chat_handle_join VALUES (2, 2);
        INSERT INTO chat_handle_join VALUES (2, 3);

        INSERT INTO message (ROWID, guid, text, handle_id, is_from_me, date, is_read) VALUES
            (1, 'm1', 'running 10 min late', 1, 0, \(ns(800_000_000)), 0),
            (2, 'm2', 'ok!', 0, 1, \(ns(800_000_100)), 1),
            (3, 'm3', 'lunch friday?', 2, 0, \(ns(800_000_200)), 1);
        INSERT INTO message (ROWID, guid, text, handle_id, is_from_me, date, is_read, associated_message_type) VALUES
            (4, 'm4', 'Loved "lunch friday?"', 3, 0, \(ns(800_000_300)), 1, 2000);
        INSERT INTO message (ROWID, guid, text, attributedBody, handle_id, is_from_me, date, is_read) VALUES
            (5, 'm5', NULL, X'\(blobHex)', 3, 0, \(ns(800_000_400)), 1);

        INSERT INTO chat_message_join VALUES (1, 1, \(ns(800_000_000)));
        INSERT INTO chat_message_join VALUES (1, 2, \(ns(800_000_100)));
        INSERT INTO chat_message_join VALUES (2, 3, \(ns(800_000_200)));
        INSERT INTO chat_message_join VALUES (2, 4, \(ns(800_000_300)));
        INSERT INTO chat_message_join VALUES (2, 5, \(ns(800_000_400)));
        """
    guard sqlite3_exec(db, statements, nil, nil, nil) == SQLITE_OK else {
        let message = String(cString: sqlite3_errmsg(db))
        throw ToolFailure("fixture SQL failed: \(message)")
    }
    return url
}

@Suite("Chat database")
struct ChatDatabaseTests {
    @Test("recent orders by last message with previews, unread counts, and names")
    func recent() async throws {
        let database = ChatDatabase(path: try makeFixture().path)
        let conversations = try await database.recentConversations(limit: 10)
        #expect(conversations.count == 2)

        let studio = try #require(conversations.first)
        #expect(studio.id == "iMessage;+;chat123")
        #expect(studio.name == "Studio friends")
        #expect(studio.isGroup)
        #expect(Set(studio.participants) == ["alex@studio.com", "+15559990000"])
        #expect(studio.lastMessage == "see you there")
        #expect(studio.lastFromMe == false)
        #expect(studio.unreadCount == 0)

        let maya = try #require(conversations.last)
        #expect(maya.id == "iMessage;-;+15551234567")
        #expect(maya.name == "+15551234567")
        #expect(maya.isGroup == false)
        #expect(maya.lastMessage == "ok!")
        #expect(maya.lastFromMe)
        #expect(maya.lastAt == Date(timeIntervalSinceReferenceDate: 800_000_100))
        #expect(maya.unreadCount == 1)
    }

    @Test("a reaction row never becomes a preview")
    func reactionsExcluded() async throws {
        let database = ChatDatabase(path: try makeFixture().path)
        let conversations = try await database.recentConversations(limit: 10)
        #expect(conversations.allSatisfy { !$0.lastMessage.contains("Loved") })
    }

    @Test("search matches text, maps senders, and converts Apple epoch dates")
    func search() async throws {
        let database = ChatDatabase(path: try makeFixture().path)
        let hits = try await database.searchMessages(query: "lunch", contact: nil, limit: 10)
        #expect(hits.count == 1)
        #expect(hits.first?.sender == "alex@studio.com")
        #expect(hits.first?.conversation == "Studio friends")
        #expect(hits.first?.at == Date(timeIntervalSinceReferenceDate: 800_000_200))

        let mine = try await database.searchMessages(query: "ok", contact: nil, limit: 10)
        #expect(mine.first?.sender == "me")
    }

    @Test("the contact filter narrows search to one conversation")
    func searchContactFilter() async throws {
        let database = ChatDatabase(path: try makeFixture().path)
        let all = try await database.searchMessages(query: "l", contact: nil, limit: 10)
        #expect(all.count >= 2)
        let filtered = try await database.searchMessages(
            query: "l", contact: "+1555123", limit: 10)
        #expect(filtered.allSatisfy { $0.conversationId == "iMessage;-;+15551234567" })
        #expect(!filtered.isEmpty)
    }

    @Test("conversation targeting resolves handles and display names")
    func targeting() async throws {
        let database = ChatDatabase(path: try makeFixture().path)
        let maya = try await database.conversationTarget(matching: "+15551234567")
        #expect(maya?.guid == "iMessage;-;+15551234567")
        #expect(maya?.isGroup == false)
        #expect(maya?.identifier == "+15551234567")

        let studio = try await database.conversationTarget(matching: "Studio friends")
        #expect(studio?.guid == "iMessage;+;chat123")
        #expect(studio?.isGroup == true)

        let nobody = try await database.conversationTarget(matching: "nobody-here")
        #expect(nobody == nil)
    }

    @Test("unread counts only inbound unread messages")
    func unread() async throws {
        let database = ChatDatabase(path: try makeFixture().path)
        #expect(try await database.unreadCount(chatGUID: "iMessage;-;+15551234567") == 1)
        #expect(try await database.unreadCount(chatGUID: "iMessage;+;chat123") == 0)
    }

    @Test("a missing database fails with the Full Disk Access sentence")
    func missingDatabase() async {
        let database = ChatDatabase(path: "/nonexistent/honeycrisp/chat.db")
        do {
            _ = try await database.recentConversations(limit: 5)
            Issue.record("expected a ToolFailure")
        } catch let failure as ToolFailure {
            #expect(failure.message.contains("Full Disk Access"))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }
}
