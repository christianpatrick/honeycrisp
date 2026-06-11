import Foundation
import SQLite3

/// Read-only access to the Messages database (tier 2 in the AGENTS.md
/// hierarchy). Opens with SQLITE_OPEN_READONLY and never writes; the
/// Messages daemon owns this store.
public actor ChatDatabase: ChatDatabaseReading {
    /// Owns the sqlite handle so it closes when the actor goes away,
    /// without needing an isolated deinit (which requires macOS 15.4).
    private final class Connection: @unchecked Sendable {
        let db: OpaquePointer
        init(db: OpaquePointer) { self.db = db }
        deinit { sqlite3_close_v2(db) }
    }

    private let path: String
    private var connection: Connection?

    public init(path: String = NSHomeDirectory() + "/Library/Messages/chat.db") {
        self.path = path
    }

    // MARK: - Reads

    public func recentConversations(limit: Int, since: Date?, unreadOnly: Bool) async throws
        -> [Conversation]
    {
        let db = try open()
        // The newest real message per chat; reactions and system rows are
        // not messages.
        var sql = """
            SELECT c.ROWID, c.guid, c.chat_identifier, c.display_name, c.style,
                   m.text, m.attributedBody, m.is_from_me, m.date
            FROM chat c
            JOIN (
                SELECT cmj.chat_id AS chat_id, MAX(m.date) AS last_date
                FROM chat_message_join cmj
                JOIN message m ON m.ROWID = cmj.message_id
                WHERE m.item_type = 0 AND m.associated_message_type = 0
                GROUP BY cmj.chat_id
            ) latest ON latest.chat_id = c.ROWID
            JOIN chat_message_join cmj2 ON cmj2.chat_id = c.ROWID
            JOIN message m ON m.ROWID = cmj2.message_id AND m.date = latest.last_date
            WHERE m.item_type = 0 AND m.associated_message_type = 0
            """
        if since != nil {
            sql += " AND latest.last_date >= ?2"
        }
        if unreadOnly {
            sql += """
                 AND EXISTS (
                    SELECT 1 FROM chat_message_join u
                    JOIN message um ON um.ROWID = u.message_id
                    WHERE u.chat_id = c.ROWID AND um.is_read = 0 AND um.is_from_me = 0
                      AND um.item_type = 0 AND um.associated_message_type = 0
                )
                """
        }
        sql += """

            GROUP BY c.ROWID
            ORDER BY latest.last_date DESC
            LIMIT ?1
            """
        var conversations: [Conversation] = []
        try query(db, sql, bind: { statement in
            sqlite3_bind_int(statement, 1, Int32(max(0, limit)))
            if let since {
                sqlite3_bind_int64(statement, 2, Self.appleNanoseconds(since))
            }
        }) { statement in
            let chatRow = sqlite3_column_int64(statement, 0)
            let guid = column(statement, 1) ?? ""
            let identifier = column(statement, 2) ?? ""
            let displayName = column(statement, 3)
            let isGroup = sqlite3_column_int(statement, 4) != 45
            let text = column(statement, 5)
            let blob = blobColumn(statement, 6)
            let fromMe = sqlite3_column_int(statement, 7) == 1
            let date = appleDate(sqlite3_column_int64(statement, 8))

            let participants = try self.participants(db, chatRow: chatRow)
            let name: String
            if let displayName, !displayName.isEmpty {
                name = displayName
            } else if !isGroup, let first = participants.first {
                name = first
            } else {
                name = participants.joined(separator: ", ")
            }
            conversations.append(
                Conversation(
                    id: guid,
                    name: name.isEmpty ? identifier : name,
                    isGroup: isGroup,
                    participants: participants,
                    lastMessage: Self.messageText(text: text, body: blob),
                    lastFromMe: fromMe,
                    lastAt: date,
                    unreadCount: try self.unread(db, chatRow: chatRow)
                ))
        }
        return conversations
    }

    public func searchMessages(
        query text: String?, contact: String?, since: Date?, until: Date?, limit: Int
    ) async throws -> [MessageHit] {
        let db = try open()
        var sql = """
            SELECT m.text, m.attributedBody, m.is_from_me, m.date, h.id,
                   c.guid, c.chat_identifier, c.display_name, c.style
            FROM message m
            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            JOIN chat c ON c.ROWID = cmj.chat_id
            LEFT JOIN handle h ON h.ROWID = m.handle_id
            WHERE m.item_type = 0 AND m.associated_message_type = 0
            """
        if text != nil {
            sql += " AND m.text LIKE '%' || ?1 || '%'"
        }
        sql += """

              AND (?2 IS NULL
                   OR c.chat_identifier LIKE '%' || ?2 || '%'
                   OR c.display_name LIKE '%' || ?2 || '%'
                   OR h.id LIKE '%' || ?2 || '%')
            """
        if since != nil {
            sql += " AND m.date >= ?4"
        }
        if until != nil {
            sql += " AND m.date < ?5"
        }
        sql += """

            ORDER BY m.date DESC
            LIMIT ?3
            """
        var hits: [MessageHit] = []
        try query(db, sql, bind: { statement in
            if let text {
                bindText(statement, 1, text)
            }
            if let contact {
                bindText(statement, 2, contact)
            } else {
                sqlite3_bind_null(statement, 2)
            }
            sqlite3_bind_int(statement, 3, Int32(max(0, limit)))
            if let since {
                sqlite3_bind_int64(statement, 4, Self.appleNanoseconds(since))
            }
            if let until {
                sqlite3_bind_int64(statement, 5, Self.appleNanoseconds(until))
            }
        }) { statement in
            hits.append(Self.hitRow(statement))
        }
        return hits
    }

    public func history(conversation: String, since: Date?, limit: Int) async throws
        -> [MessageHit]
    {
        guard let target = try await conversationTarget(matching: conversation) else {
            throw ToolFailure(
                "No Messages conversation matched \u{201C}\(conversation)\u{201D}.")
        }
        let db = try open()
        var sql = """
            SELECT m.text, m.attributedBody, m.is_from_me, m.date, h.id,
                   c.guid, c.chat_identifier, c.display_name, c.style
            FROM message m
            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            JOIN chat c ON c.ROWID = cmj.chat_id
            LEFT JOIN handle h ON h.ROWID = m.handle_id
            WHERE c.guid = ?1 AND m.item_type = 0 AND m.associated_message_type = 0
            """
        if since != nil {
            sql += " AND m.date >= ?3"
        }
        // Newest N within the window, then flipped to transcript order.
        sql += """

            ORDER BY m.date DESC
            LIMIT ?2
            """
        var hits: [MessageHit] = []
        try query(db, sql, bind: { statement in
            bindText(statement, 1, target.guid)
            sqlite3_bind_int(statement, 2, Int32(max(0, limit)))
            if let since {
                sqlite3_bind_int64(statement, 3, Self.appleNanoseconds(since))
            }
        }) { statement in
            hits.append(Self.hitRow(statement))
        }
        return hits.reversed()
    }

    private static func hitRow(_ statement: OpaquePointer) -> MessageHit {
        let body = Self.messageText(
            text: column(statement, 0), body: blobColumn(statement, 1))
        let fromMe = sqlite3_column_int(statement, 2) == 1
        let date = Date(
            timeIntervalSinceReferenceDate: Double(sqlite3_column_int64(statement, 3))
                / 1_000_000_000)
        let sender = column(statement, 4)
        let guid = column(statement, 5) ?? ""
        let identifier = column(statement, 6) ?? ""
        let displayName = column(statement, 7)
        return MessageHit(
            conversation: (displayName?.isEmpty == false ? displayName! : nil)
                ?? sender ?? identifier,
            conversationId: guid,
            sender: fromMe ? "me" : (sender ?? identifier),
            text: body,
            at: date
        )
    }

    /// chat.db speaks nanoseconds since 2001-01-01.
    private static func appleNanoseconds(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSinceReferenceDate * 1_000_000_000)
    }

    public func conversationTarget(matching needle: String) async throws -> ChatTarget? {
        let db = try open()
        // 1:1 by handle first, then display name, then chat identifier.
        let byHandle = """
            SELECT c.guid, h.id, c.display_name
            FROM chat c
            JOIN chat_handle_join chj ON chj.chat_id = c.ROWID
            JOIN handle h ON h.ROWID = chj.handle_id
            WHERE c.style = 45 AND (h.id = ?1 COLLATE NOCASE OR h.id LIKE '%' || ?1)
            ORDER BY c.ROWID DESC LIMIT 1
            """
        var target: ChatTarget?
        try query(db, byHandle, bind: { bindText($0, 1, needle) }) { statement in
            target = ChatTarget(
                guid: column(statement, 0) ?? "",
                identifier: column(statement, 1) ?? "",
                displayName: column(statement, 2),
                isGroup: false
            )
        }
        if let target { return target }

        let byName = """
            SELECT c.guid, c.chat_identifier, c.display_name, c.style
            FROM chat c
            WHERE c.display_name LIKE '%' || ?1 || '%' OR c.chat_identifier = ?1 COLLATE NOCASE
            ORDER BY c.ROWID DESC LIMIT 1
            """
        try query(db, byName, bind: { bindText($0, 1, needle) }) { statement in
            let isGroup = sqlite3_column_int(statement, 3) != 45
            var identifier = column(statement, 1) ?? ""
            if !isGroup {
                identifier = (try? self.participants(db, chatGUID: column(statement, 0) ?? ""))?
                    .first ?? identifier
            }
            target = ChatTarget(
                guid: column(statement, 0) ?? "",
                identifier: identifier,
                displayName: column(statement, 2),
                isGroup: isGroup
            )
        }
        return target
    }

    public func unreadCount(chatGUID: String) async throws -> Int {
        let db = try open()
        var count = 0
        let sql = """
            SELECT COUNT(*)
            FROM message m
            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            JOIN chat c ON c.ROWID = cmj.chat_id
            WHERE c.guid = ?1 AND m.is_read = 0 AND m.is_from_me = 0
              AND m.item_type = 0 AND m.associated_message_type = 0
            """
        try query(db, sql, bind: { bindText($0, 1, chatGUID) }) { statement in
            count = Int(sqlite3_column_int(statement, 0))
        }
        return count
    }

    // MARK: - Row helpers

    private func participants(_ db: OpaquePointer, chatRow: Int64) throws -> [String] {
        var handles: [String] = []
        let sql = """
            SELECT h.id FROM handle h
            JOIN chat_handle_join chj ON chj.handle_id = h.ROWID
            WHERE chj.chat_id = ?1
            """
        try query(db, sql, bind: { sqlite3_bind_int64($0, 1, chatRow) }) { statement in
            if let id = column(statement, 0) { handles.append(id) }
        }
        return handles
    }

    private func participants(_ db: OpaquePointer, chatGUID: String) throws -> [String] {
        var handles: [String] = []
        let sql = """
            SELECT h.id FROM handle h
            JOIN chat_handle_join chj ON chj.handle_id = h.ROWID
            JOIN chat c ON c.ROWID = chj.chat_id
            WHERE c.guid = ?1
            """
        try query(db, sql, bind: { bindText($0, 1, chatGUID) }) { statement in
            if let id = column(statement, 0) { handles.append(id) }
        }
        return handles
    }

    private func unread(_ db: OpaquePointer, chatRow: Int64) throws -> Int {
        var count = 0
        let sql = """
            SELECT COUNT(*) FROM message m
            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            WHERE cmj.chat_id = ?1 AND m.is_read = 0 AND m.is_from_me = 0
              AND m.item_type = 0 AND m.associated_message_type = 0
            """
        try query(db, sql, bind: { sqlite3_bind_int64($0, 1, chatRow) }) { statement in
            count = Int(sqlite3_column_int(statement, 0))
        }
        return count
    }

    private static func messageText(text: String?, body: Data?) -> String {
        if let text, !text.isEmpty { return text }
        if let body, let extracted = TypedStreamText.extract(from: body) { return extracted }
        return "(rich message)"
    }

    /// chat.db dates are nanoseconds since 2001-01-01.
    private func appleDate(_ nanoseconds: Int64) -> Date {
        Date(timeIntervalSinceReferenceDate: Double(nanoseconds) / 1_000_000_000)
    }

    // MARK: - SQLite plumbing

    private func open() throws -> OpaquePointer {
        if let connection { return connection.db }
        var db: OpaquePointer?
        let result = sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil)
        guard result == SQLITE_OK, let db else {
            if let db { sqlite3_close_v2(db) }
            throw ToolFailure(
                "Honeycrisp cannot read the Messages database. Grant Honeycrisp Full Disk Access in System Settings under Privacy & Security, then try again."
            )
        }
        sqlite3_busy_timeout(db, 2000)
        connection = Connection(db: db)
        return db
    }

    private func query(
        _ db: OpaquePointer,
        _ sql: String,
        bind: (OpaquePointer) -> Void,
        row: (OpaquePointer) throws -> Void
    ) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw ToolFailure(
                "The Messages database did not accept a query: \(String(cString: sqlite3_errmsg(db)))."
            )
        }
        defer { sqlite3_finalize(statement) }
        bind(statement)
        while sqlite3_step(statement) == SQLITE_ROW {
            try row(statement)
        }
    }
}

/// Pulls the plain text out of an attributedBody typedstream blob. The
/// layout this matches (0x84 0x01 0x2B, then a 1, 2, or 4 byte length,
/// then UTF-8) is the one the Messages archiver writes; HC-012 verifies it
/// against real rows, and anything unrecognized reads "(rich message)".
enum TypedStreamText {
    static func extract(from data: Data) -> String? {
        let bytes = [UInt8](data)
        let marker: [UInt8] = [0x84, 0x01, 0x2B]
        guard bytes.count > marker.count + 1 else { return nil }
        var index = 0
        while index <= bytes.count - marker.count - 1 {
            if bytes[index] == marker[0], bytes[index + 1] == marker[1],
                bytes[index + 2] == marker[2]
            {
                var cursor = index + marker.count
                let length: Int
                let first = bytes[cursor]
                if first < 0x80 {
                    length = Int(first)
                    cursor += 1
                } else if first == 0x81, cursor + 2 < bytes.count {
                    length = Int(bytes[cursor + 1]) | (Int(bytes[cursor + 2]) << 8)
                    cursor += 3
                } else if first == 0x82, cursor + 4 < bytes.count {
                    length =
                        Int(bytes[cursor + 1]) | (Int(bytes[cursor + 2]) << 8)
                        | (Int(bytes[cursor + 3]) << 16) | (Int(bytes[cursor + 4]) << 24)
                    cursor += 5
                } else {
                    index += 1
                    continue
                }
                guard length > 0, cursor + length <= bytes.count else {
                    index += 1
                    continue
                }
                if let text = String(
                    bytes: bytes[cursor..<cursor + length], encoding: .utf8), !text.isEmpty
                {
                    return text
                }
            }
            index += 1
        }
        return nil
    }
}
