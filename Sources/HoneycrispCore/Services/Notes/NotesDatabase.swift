import Foundation
import SQLite3

/// Read-only access to the Notes database (tier 2 in the AGENTS.md
/// hierarchy). Opens NoteStore.sqlite with SQLITE_OPEN_READONLY and never
/// writes; the Notes app owns this store.
///
/// Core Data lays the store out as one inheritance table whose column
/// names drift across macOS versions (ZTITLE1, ZACCOUNT7, ZCREATIONDATE3
/// and friends), so nothing positional is hardcoded: entity ids come from
/// Z_PRIMARYKEY and every property reads through a probed column family,
/// newest suffix first, following the HC-019 precedent.
public actor NotesDatabase: NotesDatabaseReading {
    private final class Connection: @unchecked Sendable {
        let db: OpaquePointer
        init(db: OpaquePointer) { self.db = db }
        deinit { sqlite3_close_v2(db) }
    }

    /// How this Notes version names things, probed once per connection.
    private struct Layout {
        let noteEntities: [Int64]
        let folderEntities: [Int64]
        let attachmentEntities: [Int64]
        let storeUUID: String?
        let title: [String]
        let snippet: [String]
        let identifier: [String]
        let created: [String]
        let modified: [String]
        let pinned: [String]
        let locked: [String]
        let deleted: [String]
        let folderRef: [String]
        let accountRef: [String]
        let noteRef: [String]
        let noteData: [String]
        let accountName: [String]
        let folderType: [String]
        let shareData: [String]

        /// COALESCE over a family, or nil when the family is absent.
        func expr(_ family: [String], _ alias: String) -> String? {
            guard let first = family.first else { return nil }
            guard family.count > 1 else { return "\(alias).\(first)" }
            return "COALESCE(" + family.map { "\(alias).\($0)" }.joined(separator: ", ") + ")"
        }

        func exprOrNull(_ family: [String], _ alias: String) -> String {
            expr(family, alias) ?? "NULL"
        }

        /// A boolean read: absent columns and NULLs read as 0.
        func flag(_ family: [String], _ alias: String) -> String {
            guard let expression = expr(family, alias) else { return "0" }
            return "COALESCE(\(expression), 0)"
        }

        func sharedExpr(_ alias: String) -> String {
            guard let expression = expr(shareData, alias) else { return "0" }
            return "(\(expression) IS NOT NULL)"
        }

        /// Trash and smart folders are containers a note cannot really
        /// live in: the trash by folder type 1 (with the CloudKit
        /// identifier as a fallback signal), smart folders by type 3.
        func notTrash(_ alias: String) -> String {
            var clauses = ["COALESCE(\(exprOrNull(identifier, alias)), '') NOT LIKE 'TrashFolder%'"]
            if let type = expr(folderType, alias) {
                clauses.append("COALESCE(\(type), 0) != 1")
            }
            return clauses.joined(separator: " AND ")
        }

        func notSmart(_ alias: String) -> String {
            guard let type = expr(folderType, alias) else { return "1 = 1" }
            return "COALESCE(\(type), 0) != 3"
        }

        func entityList(_ entities: [Int64]) -> String {
            entities.map(String.init).joined(separator: ", ")
        }
    }

    private let path: String
    private var connection: Connection?
    private var layout: Layout?

    public init(
        path: String = NSHomeDirectory()
            + "/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite"
    ) {
        self.path = path
    }

    // MARK: - Reads

    public func search(
        query needle: String?, folder: String?, since: Date?, until: Date?,
        pinnedOnly: Bool, limit: Int
    ) async throws -> [NoteSummary] {
        let db = try open()
        let layout = try probeLayout(db)
        let modified = layout.exprOrNull(layout.modified, "n")
        var sql = summarySelect(layout) + "\nWHERE " + liveNoteClause(layout)
        if needle != nil {
            sql += """

                  AND (\(layout.exprOrNull(layout.title, "n")) LIKE '%' || ?1 || '%'
                       OR \(layout.exprOrNull(layout.snippet, "n")) LIKE '%' || ?1 || '%')
                """
        }
        sql += "\n  AND (?2 IS NULL OR \(layout.exprOrNull(layout.title, "f")) LIKE '%' || ?2 || '%')"
        if since != nil {
            sql += "\n  AND \(modified) >= ?4"
        }
        if until != nil {
            sql += "\n  AND \(modified) < ?5"
        }
        if pinnedOnly {
            sql += "\n  AND \(layout.flag(layout.pinned, "n")) = 1"
        }
        sql += """

            ORDER BY (\(modified) IS NULL) ASC, \(modified) DESC
            LIMIT ?3
            """
        var notes: [NoteSummary] = []
        try query(db, sql, bind: { statement in
            if let needle {
                bindText(statement, 1, needle)
            }
            if let folder {
                bindText(statement, 2, folder)
            } else {
                sqlite3_bind_null(statement, 2)
            }
            sqlite3_bind_int(statement, 3, Int32(max(0, limit)))
            if let since {
                sqlite3_bind_double(statement, 4, since.timeIntervalSinceReferenceDate)
            }
            if let until {
                sqlite3_bind_double(statement, 5, until.timeIntervalSinceReferenceDate)
            }
        }) { statement in
            notes.append(Self.summaryRow(statement))
        }
        return notes
    }

    public func folders() async throws -> [NoteFolder] {
        let db = try open()
        let layout = try probeLayout(db)
        guard let folderRef = layout.expr(layout.folderRef, "n") else { return [] }
        let sql = """
            SELECT \(layout.exprOrNull(layout.title, "f")),
                   \(layout.exprOrNull(layout.accountName, "a")),
                   (SELECT COUNT(*) FROM ZICCLOUDSYNCINGOBJECT n
                     WHERE n.Z_ENT IN (\(layout.entityList(layout.noteEntities)))
                       AND \(folderRef) = f.Z_PK
                       AND \(layout.flag(layout.deleted, "n")) = 0)
            FROM ZICCLOUDSYNCINGOBJECT f
            LEFT JOIN ZICCLOUDSYNCINGOBJECT a ON a.Z_PK = \(layout.exprOrNull(layout.accountRef, "f"))
            WHERE f.Z_ENT IN (\(layout.entityList(layout.folderEntities)))
              AND \(layout.flag(layout.deleted, "f")) = 0
              AND \(layout.notTrash("f"))
              AND \(layout.notSmart("f"))
            ORDER BY 2 ASC, 1 ASC
            """
        var folders: [NoteFolder] = []
        try query(db, sql, bind: { _ in }) { statement in
            folders.append(
                NoteFolder(
                    name: column(statement, 0) ?? "",
                    account: column(statement, 1) ?? "",
                    notes: Int(sqlite3_column_int(statement, 2))
                ))
        }
        return folders
    }

    public func note(id: String) async throws -> NoteDetail? {
        let db = try open()
        let layout = try probeLayout(db)
        let dataJoin: String
        if let noteData = layout.expr(layout.noteData, "n") {
            dataJoin = "LEFT JOIN ZICNOTEDATA d ON d.Z_PK = \(noteData)"
        } else {
            dataJoin = "LEFT JOIN ZICNOTEDATA d ON d.ZNOTE = n.Z_PK"
        }
        let sql = summarySelect(layout, extraColumns: ", d.ZDATA", extraJoins: dataJoin)
            + "\nWHERE " + liveNoteClause(layout)
            + "\n  AND UPPER(\(layout.exprOrNull(layout.identifier, "n"))) = UPPER(?1)"
            + "\nLIMIT 1"
        var detail: NoteDetail?
        try query(db, sql, bind: { bindText($0, 1, id) }) { statement in
            let summary = Self.summaryRow(statement)
            let body: String
            if summary.locked {
                body = ""
            } else if let blob = blobColumn(statement, 11), let text = NoteBody.text(from: blob) {
                body = text
            } else {
                body = "(note text unavailable)"
            }
            detail = NoteDetail(
                id: summary.id, title: summary.title, body: body, folder: summary.folder,
                account: summary.account, createdAt: summary.createdAt,
                modifiedAt: summary.modifiedAt, pinned: summary.pinned,
                locked: summary.locked, shared: summary.shared
            )
        }
        return detail
    }

    public func scriptTarget(id: String) async throws -> NoteScriptTarget? {
        let db = try open()
        let layout = try probeLayout(db)
        guard let storeUUID = layout.storeUUID else { return nil }
        let attachments: String
        if !layout.attachmentEntities.isEmpty, let noteRef = layout.expr(layout.noteRef, "t") {
            attachments = """
                (SELECT COUNT(*) FROM ZICCLOUDSYNCINGOBJECT t
                  WHERE t.Z_ENT IN (\(layout.entityList(layout.attachmentEntities)))
                    AND \(noteRef) = n.Z_PK
                    AND \(layout.flag(layout.deleted, "t")) = 0)
                """
        } else {
            attachments = "0"
        }
        let sql = """
            SELECT n.Z_PK, \(layout.exprOrNull(layout.title, "n")),
                   \(layout.flag(layout.locked, "n")), \(attachments)
            FROM ZICCLOUDSYNCINGOBJECT n
            WHERE n.Z_ENT IN (\(layout.entityList(layout.noteEntities)))
              AND UPPER(\(layout.exprOrNull(layout.identifier, "n"))) = UPPER(?1)
            LIMIT 1
            """
        var target: NoteScriptTarget?
        try query(db, sql, bind: { bindText($0, 1, id) }) { statement in
            let primaryKey = sqlite3_column_int64(statement, 0)
            target = NoteScriptTarget(
                appleScriptID: "x-coredata://\(storeUUID)/ICNote/p\(primaryKey)",
                title: column(statement, 1) ?? "",
                locked: sqlite3_column_int(statement, 2) == 1,
                hasAttachments: sqlite3_column_int(statement, 3) > 0
            )
        }
        return target
    }

    public func noteByPrimaryKey(_ primaryKey: Int64) async throws -> NoteSummary? {
        let db = try open()
        let layout = try probeLayout(db)
        let sql = summarySelect(layout)
            + "\nWHERE n.Z_ENT IN (\(layout.entityList(layout.noteEntities))) AND n.Z_PK = ?1"
            + "\nLIMIT 1"
        var note: NoteSummary?
        try query(db, sql, bind: { sqlite3_bind_int64($0, 1, primaryKey) }) { statement in
            note = Self.summaryRow(statement)
        }
        return note
    }

    // MARK: - SQL building

    private func summarySelect(
        _ layout: Layout, extraColumns: String = "", extraJoins: String = ""
    ) -> String {
        var sql = """
            SELECT \(layout.exprOrNull(layout.identifier, "n")),
                   \(layout.exprOrNull(layout.title, "n")),
                   \(layout.exprOrNull(layout.snippet, "n")),
                   \(layout.exprOrNull(layout.title, "f")),
                   \(layout.exprOrNull(layout.accountName, "a")),
                   \(layout.exprOrNull(layout.created, "n")),
                   \(layout.exprOrNull(layout.modified, "n")),
                   \(layout.flag(layout.pinned, "n")),
                   \(layout.flag(layout.locked, "n")),
                   \(layout.sharedExpr("n")),
                   n.Z_PK\(extraColumns)
            FROM ZICCLOUDSYNCINGOBJECT n
            LEFT JOIN ZICCLOUDSYNCINGOBJECT f ON f.Z_PK = \(layout.exprOrNull(layout.folderRef, "n"))
            LEFT JOIN ZICCLOUDSYNCINGOBJECT a ON a.Z_PK = \(layout.exprOrNull(layout.accountRef, "f"))
            """
        if !extraJoins.isEmpty {
            sql += "\n" + extraJoins
        }
        return sql
    }

    private func liveNoteClause(_ layout: Layout) -> String {
        """
        n.Z_ENT IN (\(layout.entityList(layout.noteEntities)))
          AND \(layout.flag(layout.deleted, "n")) = 0
          AND (f.Z_PK IS NULL
               OR (\(layout.flag(layout.deleted, "f")) = 0 AND \(layout.notTrash("f"))))
        """
    }

    private static func summaryRow(_ statement: OpaquePointer) -> NoteSummary {
        NoteSummary(
            id: column(statement, 0) ?? "",
            title: column(statement, 1) ?? "",
            snippet: column(statement, 2) ?? "",
            folder: column(statement, 3) ?? "",
            account: column(statement, 4) ?? "",
            createdAt: dateColumn(statement, 5),
            modifiedAt: dateColumn(statement, 6),
            pinned: sqlite3_column_int(statement, 7) == 1,
            locked: sqlite3_column_int(statement, 8) == 1,
            shared: sqlite3_column_int(statement, 9) == 1
        )
    }

    /// NoteStore dates are Core Data seconds since 2001-01-01.
    private static func dateColumn(_ statement: OpaquePointer, _ index: Int32) -> Date? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, index))
    }

    // MARK: - Layout probing

    private func probeLayout(_ db: OpaquePointer) throws -> Layout {
        if let layout { return layout }

        var columns: [String] = []
        try query(db, "PRAGMA table_info(ZICCLOUDSYNCINGOBJECT)", bind: { _ in }) { statement in
            if let name = column(statement, 1) { columns.append(name.uppercased()) }
        }

        struct EntityRow {
            let ent: Int64
            let name: String
            let superEnt: Int64
        }
        var entities: [EntityRow] = []
        try query(
            db, "SELECT Z_ENT, Z_NAME, Z_SUPER FROM Z_PRIMARYKEY", bind: { _ in }
        ) { statement in
            entities.append(
                EntityRow(
                    ent: sqlite3_column_int64(statement, 0),
                    name: column(statement, 1) ?? "",
                    superEnt: sqlite3_column_int64(statement, 2)
                ))
        }
        // An entity and everything under it in the inheritance tree.
        func descendants(of name: String) -> [Int64] {
            guard let root = entities.first(where: { $0.name == name }) else { return [] }
            var result = [root.ent]
            var grew = true
            while grew {
                grew = false
                for row in entities
                where result.contains(row.superEnt) && !result.contains(row.ent) {
                    result.append(row.ent)
                    grew = true
                }
            }
            return result.sorted()
        }

        // The newest model's column wins when a family has grown a suffix
        // over the years, like ZCREATIONDATE3 over ZCREATIONDATE1.
        func family(_ base: String) -> [String] {
            columns
                .filter { name in
                    name == base
                        || (name.hasPrefix(base)
                            && name.dropFirst(base.count).allSatisfy(\.isNumber))
                }
                .sorted { left, right in
                    (Int(left.dropFirst(base.count)) ?? -1)
                        > (Int(right.dropFirst(base.count)) ?? -1)
                }
        }

        let probed = Layout(
            noteEntities: descendants(of: "ICNote"),
            folderEntities: descendants(of: "ICFolder"),
            attachmentEntities: descendants(of: "ICAttachment"),
            storeUUID: try storeUUID(db),
            title: family("ZTITLE"),
            snippet: family("ZSNIPPET"),
            identifier: family("ZIDENTIFIER"),
            created: family("ZCREATIONDATE"),
            modified: family("ZMODIFICATIONDATE"),
            pinned: family("ZISPINNED"),
            locked: family("ZISPASSWORDPROTECTED"),
            deleted: family("ZMARKEDFORDELETION"),
            folderRef: family("ZFOLDER"),
            accountRef: family("ZACCOUNT"),
            noteRef: family("ZNOTE"),
            noteData: family("ZNOTEDATA"),
            accountName: family("ZNAME"),
            folderType: family("ZFOLDERTYPE"),
            shareData: family("ZSERVERSHAREDATA")
        )
        guard
            !probed.noteEntities.isEmpty,
            !probed.title.isEmpty,
            !probed.identifier.isEmpty
        else {
            throw ToolFailure(
                "Honeycrisp did not recognize the layout of the Notes database on this Mac."
            )
        }
        layout = probed
        return probed
    }

    private func storeUUID(_ db: OpaquePointer) throws -> String? {
        var uuid: String?
        try? query(db, "SELECT Z_UUID FROM Z_METADATA LIMIT 1", bind: { _ in }) { statement in
            uuid = column(statement, 0)
        }
        return uuid
    }

    // MARK: - SQLite plumbing

    private func open() throws -> OpaquePointer {
        if let connection { return connection.db }
        var db: OpaquePointer?
        let result = sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil)
        guard result == SQLITE_OK, let db else {
            if let db { sqlite3_close_v2(db) }
            throw ToolFailure(
                "Honeycrisp cannot read the Notes database. Grant Honeycrisp Full Disk Access in System Settings under Privacy & Security, then try again."
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
                "The Notes database did not accept a query: \(String(cString: sqlite3_errmsg(db)))."
            )
        }
        defer { sqlite3_finalize(statement) }
        bind(statement)
        while sqlite3_step(statement) == SQLITE_ROW {
            try row(statement)
        }
    }
}
