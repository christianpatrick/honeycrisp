import Foundation
import SQLite3

/// Read-only access to Mail's Envelope Index and the .emlx files next to it
/// (tier 2 in the AGENTS.md hierarchy). Never writes anything Mail owns.
public actor MailDatabase: EnvelopeIndexReading {
    private final class Connection: @unchecked Sendable {
        let db: OpaquePointer
        init(db: OpaquePointer) { self.db = db }
        deinit { sqlite3_close_v2(db) }
    }

    /// How this Mail version names the recipients reference columns. Real
    /// indexes disagree (message_id/address_id on older versions, message/
    /// address on current ones), so we ask SQLite instead of assuming.
    private struct RecipientsSchema {
        let messageColumn: String
        let addressColumn: String
        let hasType: Bool
        let hasPosition: Bool
    }

    private let indexPath: String
    private let mailRoot: URL
    private var connection: Connection?
    /// nil means not probed yet; .some(nil) means unusable, degrade.
    private var recipientsSchema: RecipientsSchema??

    public init(
        indexPath: String = MailDatabase.discoverIndexPath(),
        mailRoot: URL = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Mail")
    ) {
        self.indexPath = indexPath
        self.mailRoot = mailRoot
    }

    /// The highest V* version folder owns the live index.
    public static func discoverIndexPath() -> String {
        let mail = NSHomeDirectory() + "/Library/Mail"
        let versions = ((try? FileManager.default.contentsOfDirectory(atPath: mail)) ?? [])
            .filter { $0.hasPrefix("V") }
            .compactMap { Int($0.dropFirst()) }
            .sorted()
        let version = versions.last.map { "V\($0)" } ?? "V10"
        return "\(mail)/\(version)/MailData/Envelope Index"
    }

    // MARK: - Search

    public func search(query needle: String, mailbox: String?, limit: Int) async throws
        -> [MailMessageSummary]
    {
        let db = try open()
        let sql = """
            SELECT m.ROWID, m.conversation_id, s.subject, a.address, a.comment,
                   m.date_received, m."read", mb.url
            FROM messages m
            LEFT JOIN subjects s ON s.ROWID = m.subject
            LEFT JOIN addresses a ON a.ROWID = m.sender
            LEFT JOIN mailboxes mb ON mb.ROWID = m.mailbox
            WHERE (s.subject LIKE '%' || ?1 || '%'
                   OR a.address LIKE '%' || ?1 || '%'
                   OR a.comment LIKE '%' || ?1 || '%')
              AND (?2 IS NULL OR mb.url LIKE '%' || ?2 || '%')
            ORDER BY m.date_received DESC
            LIMIT ?3
            """
        var found: [MailMessageSummary] = []
        try query(db, sql, bind: { statement in
            bindText(statement, 1, needle)
            if let mailbox {
                bindText(statement, 2, mailbox)
            } else {
                sqlite3_bind_null(statement, 2)
            }
            sqlite3_bind_int(statement, 3, Int32(max(0, limit)))
        }) { statement in
            found.append(Self.summaryRow(statement))
        }
        return found
    }

    public func messageSummary(id: String) async throws -> MailMessageSummary? {
        guard let rowID = Int64(id) else { return nil }
        let db = try open()
        let sql = """
            SELECT m.ROWID, m.conversation_id, s.subject, a.address, a.comment,
                   m.date_received, m."read", mb.url
            FROM messages m
            LEFT JOIN subjects s ON s.ROWID = m.subject
            LEFT JOIN addresses a ON a.ROWID = m.sender
            LEFT JOIN mailboxes mb ON mb.ROWID = m.mailbox
            WHERE m.ROWID = ?1
            """
        var found: MailMessageSummary?
        try query(db, sql, bind: { sqlite3_bind_int64($0, 1, rowID) }) { statement in
            found = Self.summaryRow(statement)
        }
        return found
    }

    private static func summaryRow(_ statement: OpaquePointer) -> MailMessageSummary {
        MailMessageSummary(
            id: String(sqlite3_column_int64(statement, 0)),
            threadId: String(sqlite3_column_int64(statement, 1)),
            subject: column(statement, 2) ?? "",
            from: column(statement, 3) ?? "",
            fromName: column(statement, 4),
            date: Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 5))),
            mailbox: mailboxName(fromURL: column(statement, 7)),
            read: sqlite3_column_int(statement, 6) == 1
        )
    }

    private static func mailboxName(fromURL url: String?) -> String {
        guard let url, let tail = url.split(separator: "/").last else { return "" }
        return String(tail).removingPercentEncoding ?? String(tail)
    }

    // MARK: - Thread

    public func thread(id: String, limit: Int) async throws -> MailThread {
        guard let conversation = Int64(id) else {
            throw ToolFailure("mail_read needs the numeric thread_id from mail_search.")
        }
        let db = try open()
        let sql = """
            SELECT m.ROWID, s.subject, a.address, a.comment, m.date_received
            FROM messages m
            LEFT JOIN subjects s ON s.ROWID = m.subject
            LEFT JOIN addresses a ON a.ROWID = m.sender
            WHERE m.conversation_id = ?1
            ORDER BY m.date_received ASC
            LIMIT ?2
            """
        struct Row {
            let id: Int64
            let subject: String
            let from: String
            let fromName: String?
            let date: Date
        }
        var rows: [Row] = []
        try query(db, sql, bind: { statement in
            sqlite3_bind_int64(statement, 1, conversation)
            sqlite3_bind_int(statement, 2, Int32(max(0, limit)))
        }) { statement in
            rows.append(
                Row(
                    id: sqlite3_column_int64(statement, 0),
                    subject: column(statement, 1) ?? "",
                    from: column(statement, 2) ?? "",
                    fromName: column(statement, 3),
                    date: Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 4)))
                ))
        }
        guard !rows.isEmpty else {
            throw ToolFailure("No thread matched the id \u{201C}\(id)\u{201D}.")
        }

        let bodies = Self.loadBodies(rowIDs: rows.map(\.id), under: mailRoot)
        var participants: [String] = []
        var messages: [MailMessage] = []
        for row in rows {
            let to = try recipients(db, messageRowID: row.id, type: 0)
            let cc = try recipients(db, messageRowID: row.id, type: 1)
            for address in [row.from] + to + cc where !address.isEmpty {
                if !participants.contains(address) { participants.append(address) }
            }
            messages.append(
                MailMessage(
                    id: String(row.id),
                    from: row.from,
                    fromName: row.fromName,
                    to: to,
                    date: row.date,
                    body: bodies[row.id] ?? "(body unavailable)"
                ))
        }
        return MailThread(
            id: id,
            subject: rows.first?.subject ?? "",
            participants: participants,
            messages: messages
        )
    }

    /// Recipients are a nicety; bodies are the point of mail_read. An
    /// unrecognizable recipients table degrades to empty lists instead of
    /// failing the thread.
    private func recipients(_ db: OpaquePointer, messageRowID: Int64, type: Int32) throws
        -> [String]
    {
        guard let schema = probeRecipientsSchema(db) else { return [] }
        var addresses: [String] = []
        var sql = """
            SELECT a.address FROM recipients r
            JOIN addresses a ON a.ROWID = r.\(schema.addressColumn)
            WHERE r.\(schema.messageColumn) = ?1
            """
        if schema.hasType {
            sql += " AND r.type = ?2"
        }
        sql += schema.hasPosition ? " ORDER BY r.position ASC" : " ORDER BY r.ROWID ASC"
        try query(db, sql, bind: { statement in
            sqlite3_bind_int64(statement, 1, messageRowID)
            if schema.hasType {
                sqlite3_bind_int(statement, 2, type)
            }
        }) { statement in
            if let address = column(statement, 0) { addresses.append(address) }
        }
        return addresses
    }

    private func probeRecipientsSchema(_ db: OpaquePointer) -> RecipientsSchema? {
        if let probed = recipientsSchema { return probed }
        var columns: Set<String> = []
        try? query(db, "PRAGMA table_info(recipients)", bind: { _ in }) { statement in
            if let name = column(statement, 1) { columns.insert(name.lowercased()) }
        }
        let messageColumn = ["message_id", "message"].first { columns.contains($0) }
        let addressColumn = ["address_id", "address"].first { columns.contains($0) }
        let schema: RecipientsSchema?
        if let messageColumn, let addressColumn {
            schema = RecipientsSchema(
                messageColumn: messageColumn,
                addressColumn: addressColumn,
                hasType: columns.contains("type"),
                hasPosition: columns.contains("position")
            )
        } else {
            schema = nil
        }
        recipientsSchema = .some(schema)
        return schema
    }

    /// One bounded walk for all the bodies a thread needs. The on-disk
    /// shard layout varies by Mail version, so we match filenames
    /// (ROWID.emlx or ROWID.partial.emlx) instead of guessing shards, and
    /// stop as soon as everything is found.
    private static func loadBodies(rowIDs: [Int64], under root: URL) -> [Int64: String] {
        var wanted: [String: Int64] = [:]
        for id in rowIDs {
            wanted["\(id).emlx"] = id
            wanted["\(id).partial.emlx"] = id
        }
        var bodies: [Int64: String] = [:]
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        while let entry = enumerator?.nextObject() as? URL {
            guard let id = wanted[entry.lastPathComponent] else { continue }
            guard bodies[id] == nil else { continue }
            if let data = try? Data(contentsOf: entry),
                let body = Emlx.bodyText(from: data)
            {
                bodies[id] = body
            }
            if bodies.count == Set(rowIDs).count { break }
        }
        return bodies
    }

    // MARK: - SQLite plumbing

    private func open() throws -> OpaquePointer {
        if let connection { return connection.db }
        var db: OpaquePointer?
        let result = sqlite3_open_v2(indexPath, &db, SQLITE_OPEN_READONLY, nil)
        guard result == SQLITE_OK, let db else {
            if let db { sqlite3_close_v2(db) }
            throw ToolFailure(
                "Honeycrisp cannot read Mail's index. Grant Honeycrisp Full Disk Access in System Settings under Privacy & Security, then try again."
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
                "Mail's index did not accept a query: \(String(cString: sqlite3_errmsg(db)))."
            )
        }
        defer { sqlite3_finalize(statement) }
        bind(statement)
        while sqlite3_step(statement) == SQLITE_ROW {
            try row(statement)
        }
    }
}
