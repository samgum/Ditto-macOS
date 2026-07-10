import CSystem
import Foundation

enum MacClipboardDatabaseError: Error {
    case openFailed(String)
    case prepareFailed(String)
    case executeFailed(String)
}

/// Low-level SQLite wrapper for Ditto's local database.
///
/// Schema mirrors the intent of the Windows `Main` / `Data` tables but uses a
/// UUID clip id and a separate `ClipBlobs` store for heavy format payloads.
/// `schemaVersion` lets us `ALTER TABLE` forward from earlier betas.
final class MacClipboardDatabase {
    private var database: OpaquePointer?
    private(set) var schemaVersion: Int = 0

    /// Serializes ALL sqlite access. A single `sqlite3*` connection must not
    /// be used concurrently from multiple threads (it corrupts internal state
    /// and SIGSEGVs — seen when an image capture persisted on a background
    /// queue while the main thread read entries). Recursive so that
    /// `transaction → execute → query` nesting on the same thread is safe.
    private let lock = NSRecursiveLock()

    static let currentSchemaVersion = 4

    init(url: URL, useWAL: Bool = true, readOnly: Bool = false) throws {
        if readOnly == false {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }

        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE)
        guard sqlite3_open_v2(url.path, &database, flags, nil) == SQLITE_OK else {
            let message = database.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? url.path
            throw MacClipboardDatabaseError.openFailed(message)
        }

        try execute("PRAGMA foreign_keys = ON")
        if readOnly == false {
            try execute(useWAL ? "PRAGMA journal_mode = WAL" : "PRAGMA journal_mode = DELETE")
            try execute("PRAGMA busy_timeout = 5000")
            try createTables()
            try migrate()       // ensure every column exists BEFORE indexes
            try createIndexes()
        }
    }

    deinit {
        sqlite3_close(database)
    }

    // MARK: - Schema

    private func createTables() throws {
        try execute(
            """
            CREATE TABLE IF NOT EXISTS ClipboardEntries(
                id TEXT PRIMARY KEY,
                text TEXT,
                rtfBlobKey TEXT,
                htmlBlobKey TEXT,
                imageBlobKey TEXT,
                fileURLsJson TEXT,
                createdAt REAL NOT NULL
            )
            """
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS Groups(
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL,
                parentId INTEGER,
                sortOrder REAL DEFAULT 0,
                createdAt REAL NOT NULL
            )
            """
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS ClipBlobs(
                blobKey TEXT PRIMARY KEY,
                fileExtension TEXT NOT NULL,
                data BLOB NOT NULL
            )
            """
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS CopyBuffers(
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                bufferNumber INTEGER NOT NULL,
                entryId TEXT
            )
            """
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS Friends(
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL,
                ipAddress TEXT NOT NULL,
                port INTEGER NOT NULL DEFAULT 23443,
                sendAll INTEGER NOT NULL DEFAULT 0
            )
            """
        )
    }

    private func createIndexes() throws {
        try execute("CREATE INDEX IF NOT EXISTS ClipboardEntries_createdAt ON ClipboardEntries(createdAt DESC)")
        try execute("CREATE INDEX IF NOT EXISTS ClipboardEntries_clipOrder ON ClipboardEntries(clipOrder DESC)")
        try execute("CREATE INDEX IF NOT EXISTS ClipboardEntries_groupId ON ClipboardEntries(groupId)")
        try execute("CREATE INDEX IF NOT EXISTS ClipboardEntries_shortcut ON ClipboardEntries(shortcutKey DESC, shortcutGlobal DESC)")
        try execute("CREATE INDEX IF NOT EXISTS Groups_parent ON Groups(parentId)")
    }

    /// Column-level migration. Runs UNCONDITIONALLY (idempotent) so a legacy
    /// database — e.g. one created by the upstream macOS port with an older
    /// schema — always ends up with every column the queries expect,
    /// regardless of its stored user_version.
    private func migrate() throws {
        schemaVersion = userVersion()

        // Every column ClipboardEntries needs beyond (id,text,rtfBlobKey,
        // htmlBlobKey,imageBlobKey,fileURLsJson,createdAt).
        let requiredColumns: [(String, String)] = [
            ("lastPasteDate", "REAL"),
            ("isFavorite", "INTEGER"),
            ("neverAutoDelete", "INTEGER DEFAULT 0"),
            ("quickPasteText", "TEXT"),
            ("clipOrder", "REAL DEFAULT 0"),
            ("shortcutKey", "INTEGER DEFAULT 0"),
            ("shortcutGlobal", "INTEGER DEFAULT 0"),
            ("moveToGroupShortcut", "INTEGER DEFAULT 0"),
            ("pdfBlobKey", "TEXT"),
            ("globalMoveToGroup", "INTEGER DEFAULT 0"),
            ("crc", "INTEGER"),
            ("sourceApp", "TEXT"),
            ("pasteCount", "INTEGER DEFAULT 0"),
            ("groupId", "INTEGER")
        ]
        for (column, type) in requiredColumns {
            addColumnIfMissing(table: "ClipboardEntries", column: column, type: type)
        }
        // Backfill clipOrder for legacy rows that have none / zero.
        _ = try? execute("UPDATE ClipboardEntries SET clipOrder = createdAt WHERE clipOrder IS NULL OR clipOrder = 0")

        setUserVersion(Self.currentSchemaVersion)
        schemaVersion = Self.currentSchemaVersion
    }

    private func userVersion() -> Int {
        let result: Int? = try? query("PRAGMA user_version") { statement in
            sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int(statement, 0)) : 0
        }
        return result ?? 0
    }

    private func setUserVersion(_ version: Int) {
        _ = try? execute("PRAGMA user_version = \(version)")
    }

    private func addColumnIfMissing(table: String, column: String, type: String) {
        let columns = existingColumns(in: table)
        if columns.contains(column) == false {
            _ = try? execute("ALTER TABLE \(table) ADD COLUMN \(column) \(type)")
        }
    }

    private func existingColumns(in table: String) -> [String] {
        (try? query("PRAGMA table_info(\(quoted(table)))") { statement in
            var names: [String] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                names.append(Self.string(statement, 1))
            }
            return names
        }) ?? []
    }

    private func quoted(_ identifier: String) -> String {
        "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    // MARK: - Entries

    func loadEntries() throws -> [ClipboardEntry] {
        try query(
            """
            SELECT id, text, rtfBlobKey, htmlBlobKey, imageBlobKey, fileURLsJson,
                   createdAt, lastPasteDate, isFavorite, neverAutoDelete, quickPasteText,
                   clipOrder, shortcutKey, shortcutGlobal, moveToGroupShortcut, globalMoveToGroup,
                   crc, sourceApp, pasteCount, groupId, pdfBlobKey
            FROM ClipboardEntries
            ORDER BY neverAutoDelete DESC, isFavorite DESC, clipOrder DESC, createdAt DESC
            """
        ) { statement in
            var entries: [ClipboardEntry] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let id = UUID(uuidString: Self.string(statement, 0)) else { continue }
                let fileURLs = Self.optionalString(statement, 5)
                    .flatMap { $0.data(using: .utf8) }
                    .flatMap { try? JSONDecoder().decode([String].self, from: $0) }

                entries.append(
                    ClipboardEntry(
                        id: id,
                        text: Self.optionalString(statement, 1),
                        rtfBlobKey: Self.optionalString(statement, 2),
                        htmlBlobKey: Self.optionalString(statement, 3),
                        imageBlobKey: Self.optionalString(statement, 4),
                        pdfBlobKey: Self.optionalString(statement, 20),
                        fileURLs: fileURLs,
                        createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
                        lastPasteDate: Self.optionalDate(statement, 7),
                        isFavorite: Self.optionalBool(statement, 8),
                        neverAutoDelete: sqlite3_column_int(statement, 9) != 0,
                        quickPasteText: Self.optionalString(statement, 10),
                        clipOrder: sqlite3_column_double(statement, 11),
                        shortcutKey: Int(sqlite3_column_int(statement, 12)),
                        shortcutGlobal: sqlite3_column_int(statement, 13) != 0,
                        moveToGroupShortcut: Self.optionalInt64(statement, 14) ?? 0,
                        globalMoveToGroup: sqlite3_column_int(statement, 15) != 0,
                        crc: Self.optionalInt64(statement, 16),
                        sourceApp: Self.optionalString(statement, 17),
                        pasteCount: Int(sqlite3_column_int(statement, 18)),
                        groupId: Self.optionalInt64(statement, 19)
                    )
                )
            }
            return entries
        }
    }

    func replaceEntries(_ entries: [ClipboardEntry]) throws {
        try transaction {
            try execute("DELETE FROM ClipboardEntries")
            for entry in entries {
                try upsertEntry(entry)
            }
        }
    }

    func upsertEntry(_ entry: ClipboardEntry) throws {
        let fileURLsJson = entry.fileURLs
            .flatMap { try? JSONEncoder().encode($0) }
            .flatMap { String(data: $0, encoding: .utf8) }

        try execute(
            """
            INSERT INTO ClipboardEntries(
                id, text, rtfBlobKey, htmlBlobKey, imageBlobKey, fileURLsJson,
                createdAt, lastPasteDate, isFavorite, neverAutoDelete, quickPasteText,
                clipOrder, shortcutKey, shortcutGlobal, moveToGroupShortcut, globalMoveToGroup,
                crc, sourceApp, pasteCount, groupId, pdfBlobKey
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                text=excluded.text,
                rtfBlobKey=excluded.rtfBlobKey,
                htmlBlobKey=excluded.htmlBlobKey,
                imageBlobKey=excluded.imageBlobKey,
                fileURLsJson=excluded.fileURLsJson,
                createdAt=excluded.createdAt,
                lastPasteDate=excluded.lastPasteDate,
                isFavorite=excluded.isFavorite,
                neverAutoDelete=excluded.neverAutoDelete,
                quickPasteText=excluded.quickPasteText,
                clipOrder=excluded.clipOrder,
                shortcutKey=excluded.shortcutKey,
                shortcutGlobal=excluded.shortcutGlobal,
                moveToGroupShortcut=excluded.moveToGroupShortcut,
                globalMoveToGroup=excluded.globalMoveToGroup,
                crc=excluded.crc,
                sourceApp=excluded.sourceApp,
                pasteCount=excluded.pasteCount,
                groupId=excluded.groupId,
                pdfBlobKey=excluded.pdfBlobKey
            """,
            binds: { statement in
                sqlite3_bind_text(statement, 1, entry.id.uuidString, -1, databaseTransientDestructor)
                self.bindOptionalText(statement, 2, entry.text)
                self.bindOptionalText(statement, 3, entry.rtfBlobKey)
                self.bindOptionalText(statement, 4, entry.htmlBlobKey)
                self.bindOptionalText(statement, 5, entry.imageBlobKey)
                self.bindOptionalText(statement, 6, fileURLsJson)
                sqlite3_bind_double(statement, 7, entry.createdAt.timeIntervalSince1970)
                Self.bindOptionalDate(statement, 8, entry.lastPasteDate)
                Self.bindOptionalBool(statement, 9, entry.isFavorite)
                sqlite3_bind_int(statement, 10, entry.neverAutoDelete ? 1 : 0)
                self.bindOptionalText(statement, 11, entry.quickPasteText)
                sqlite3_bind_double(statement, 12, entry.clipOrder)
                sqlite3_bind_int(statement, 13, Int32(entry.shortcutKey))
                sqlite3_bind_int(statement, 14, entry.shortcutGlobal ? 1 : 0)
                sqlite3_bind_int64(statement, 15, entry.moveToGroupShortcut)
                sqlite3_bind_int(statement, 16, entry.globalMoveToGroup ? 1 : 0)
                Self.bindOptionalInt64(statement, 17, entry.crc)
                self.bindOptionalText(statement, 18, entry.sourceApp)
                sqlite3_bind_int(statement, 19, Int32(entry.pasteCount))
                Self.bindOptionalInt64(statement, 20, entry.groupId)
                self.bindOptionalText(statement, 21, entry.pdfBlobKey)
            }
        )
    }

    func deleteEntry(id: UUID) throws {
        try execute(
            "DELETE FROM ClipboardEntries WHERE id = ?",
            binds: { sqlite3_bind_text($0, 1, id.uuidString, -1, databaseTransientDestructor) }
        )
    }

    /// Make a SQLite-consistent backup, including uncheckpointed WAL pages.
    /// A filesystem copy of the main database file alone can otherwise miss
    /// recently committed clips while WAL mode is active.
    func backup(to url: URL) throws {
        lock.lock()
        defer { lock.unlock() }

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: url.path + suffix)
            if FileManager.default.fileExists(atPath: sidecar.path) {
                try FileManager.default.removeItem(at: sidecar)
            }
        }

        var destination: OpaquePointer?
        guard sqlite3_open_v2(url.path, &destination, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            let message = destination.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? url.path
            sqlite3_close(destination)
            throw MacClipboardDatabaseError.openFailed(message)
        }
        defer { sqlite3_close(destination) }

        guard let source = database,
              let backup = sqlite3_backup_init(destination, "main", source, "main") else {
            let message = sqlite3_errmsg(destination).map { String(cString: $0) } ?? url.path
            throw MacClipboardDatabaseError.executeFailed(message)
        }
        defer { sqlite3_backup_finish(backup) }

        guard sqlite3_backup_step(backup, -1) == SQLITE_DONE else {
            let message = sqlite3_errmsg(destination).map { String(cString: $0) } ?? url.path
            throw MacClipboardDatabaseError.executeFailed(message)
        }
    }

    // MARK: - Groups

    /// Preserve group IDs in standalone history archives. Archive imports map
    /// these IDs into the destination database, avoiding collisions there.
    func replaceGroups(_ groups: [ClipGroup]) throws {
        try transaction {
            try execute("DELETE FROM Groups")
            for group in groups {
                try execute(
                    "INSERT INTO Groups(id, name, parentId, sortOrder, createdAt) VALUES (?, ?, ?, ?, ?)",
                    binds: { statement in
                        sqlite3_bind_int64(statement, 1, group.id)
                        sqlite3_bind_text(statement, 2, group.name, -1, databaseTransientDestructor)
                        if let parentId = group.parentId {
                            sqlite3_bind_int64(statement, 3, parentId)
                        } else {
                            sqlite3_bind_null(statement, 3)
                        }
                        sqlite3_bind_double(statement, 4, group.sortOrder)
                        sqlite3_bind_double(statement, 5, group.createdAt.timeIntervalSince1970)
                    }
                )
            }
        }
    }

    func loadGroups() throws -> [ClipGroup] {
        try query("SELECT id, name, parentId, sortOrder, createdAt FROM Groups ORDER BY sortOrder DESC, name ASC") { statement in
            var groups: [ClipGroup] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                let parentId = sqlite3_column_type(statement, 2) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, 2)
                groups.append(
                    ClipGroup(
                        id: sqlite3_column_int64(statement, 0),
                        name: Self.string(statement, 1),
                        parentId: parentId,
                        sortOrder: sqlite3_column_double(statement, 3),
                        createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
                    )
                )
            }
            return groups
        }
    }

    @discardableResult
    func insertGroup(_ group: ClipGroup) throws -> Int64 {
        try execute(
            "INSERT INTO Groups(name, parentId, sortOrder, createdAt) VALUES (?, ?, ?, ?)",
            binds: { statement in
                sqlite3_bind_text(statement, 1, group.name, -1, databaseTransientDestructor)
                if let parentId = group.parentId {
                    sqlite3_bind_int64(statement, 2, parentId)
                } else {
                    sqlite3_bind_null(statement, 2)
                }
                sqlite3_bind_double(statement, 3, group.sortOrder)
                sqlite3_bind_double(statement, 4, group.createdAt.timeIntervalSince1970)
            }
        )
        return sqlite3_last_insert_rowid(database)
    }

    func updateGroup(_ group: ClipGroup) throws {
        try execute(
            "UPDATE Groups SET name = ?, parentId = ?, sortOrder = ? WHERE id = ?",
            binds: { statement in
                sqlite3_bind_text(statement, 1, group.name, -1, databaseTransientDestructor)
                if let parentId = group.parentId {
                    sqlite3_bind_int64(statement, 2, parentId)
                } else {
                    sqlite3_bind_null(statement, 2)
                }
                sqlite3_bind_double(statement, 3, group.sortOrder)
                sqlite3_bind_int64(statement, 4, group.id)
            }
        )
    }

    func deleteGroup(id: Int64) throws {
        try transaction {
            // Re-parent clips and child groups to the deleted group's parent.
            let parentId = (try? query("SELECT parentId FROM Groups WHERE id = ?", binds: { sqlite3_bind_int64($0, 1, id) }) {
                sqlite3_step($0) == SQLITE_ROW ? sqlite3_column_int64($0, 0) : nil
            }) ?? nil
            if let parentId {
                try execute("UPDATE ClipboardEntries SET groupId = ? WHERE groupId = ?", binds: { stmt in
                    sqlite3_bind_int64(stmt, 1, parentId)
                    sqlite3_bind_int64(stmt, 2, id)
                })
                try execute("UPDATE Groups SET parentId = ? WHERE parentId = ?", binds: { stmt in
                    sqlite3_bind_int64(stmt, 1, parentId)
                    sqlite3_bind_int64(stmt, 2, id)
                })
            } else {
                try execute("UPDATE ClipboardEntries SET groupId = NULL WHERE groupId = ?", binds: { sqlite3_bind_int64($0, 1, id) })
                try execute("UPDATE Groups SET parentId = NULL WHERE parentId = ?", binds: { sqlite3_bind_int64($0, 1, id) })
            }
            try execute("DELETE FROM Groups WHERE id = ?", binds: { sqlite3_bind_int64($0, 1, id) })
        }
    }

    // MARK: - Blobs

    func saveBlob(_ data: Data, key: String = UUID().uuidString, fileExtension: String) throws -> String {
        try execute(
            """
            INSERT OR REPLACE INTO ClipBlobs(blobKey, fileExtension, data)
            VALUES (?, ?, ?)
            """,
            binds: { statement in
                sqlite3_bind_text(statement, 1, key, -1, databaseTransientDestructor)
                sqlite3_bind_text(statement, 2, fileExtension, -1, databaseTransientDestructor)
                _ = data.withUnsafeBytes { buffer in
                    sqlite3_bind_blob(statement, 3, buffer.baseAddress, Int32(data.count), databaseTransientDestructor)
                }
            }
        )
        return key
    }

    func blobData(key: String) -> Data? {
        try? query(
            "SELECT data FROM ClipBlobs WHERE blobKey = ?",
            binds: { sqlite3_bind_text($0, 1, key, -1, databaseTransientDestructor) }
        ) { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return Self.blob(statement, 0)
        }
    }

    func removeBlobs(keys: [String]) {
        for key in keys {
            _ = try? execute(
                "DELETE FROM ClipBlobs WHERE blobKey = ?",
                binds: { sqlite3_bind_text($0, 1, key, -1, databaseTransientDestructor) }
            )
        }
    }

    func removeAll() throws {
        try transaction {
            try execute("DELETE FROM ClipboardEntries")
            try execute("DELETE FROM ClipBlobs")
            try execute("DELETE FROM Groups")
            try execute("DELETE FROM CopyBuffers")
        }
    }

    func clearCopyBufferReferences(for entryID: UUID) throws {
        try execute(
            "DELETE FROM CopyBuffers WHERE entryId = ?",
            binds: { sqlite3_bind_text($0, 1, entryID.uuidString, -1, databaseTransientDestructor) }
        )
    }

    func vacuum() throws {
        try execute("VACUUM")
    }

    // MARK: - Copy buffers

    func loadCopyBuffers() throws -> [Int: UUID] {
        try query("SELECT bufferNumber, entryId FROM CopyBuffers") { statement in
            var buffers: [Int: UUID] = [:]
            while sqlite3_step(statement) == SQLITE_ROW {
                let number = Int(sqlite3_column_int(statement, 0))
                if let idString = sqlite3_column_text(statement, 1),
                   let id = UUID(uuidString: String(cString: idString)) {
                    buffers[number] = id
                }
            }
            return buffers
        }
    }

    func setCopyBuffer(_ buffer: Int, entryId: UUID?) throws {
        try execute("DELETE FROM CopyBuffers WHERE bufferNumber = ?", binds: { sqlite3_bind_int($0, 1, Int32(buffer)) })
        if let entryId {
            try execute(
                "INSERT INTO CopyBuffers(bufferNumber, entryId) VALUES (?, ?)",
                binds: { statement in
                    sqlite3_bind_int(statement, 1, Int32(buffer))
                    sqlite3_bind_text(statement, 2, entryId.uuidString, -1, databaseTransientDestructor)
                }
            )
        }
    }

    // MARK: - Friends

    func loadFriends() throws -> [Friend] {
        try query("SELECT id, name, ipAddress, port, sendAll FROM Friends ORDER BY name ASC") { statement in
            var friends: [Friend] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                friends.append(
                    Friend(
                        id: sqlite3_column_int64(statement, 0),
                        name: Self.string(statement, 1),
                        ipAddress: Self.string(statement, 2),
                        port: Int(sqlite3_column_int(statement, 3)),
                        sendAll: sqlite3_column_int(statement, 4) != 0
                    )
                )
            }
            return friends
        }
    }

    @discardableResult
    func upsertFriend(_ friend: Friend) throws -> Int64 {
        if friend.id == 0 {
            try execute(
                "INSERT INTO Friends(name, ipAddress, port, sendAll) VALUES (?, ?, ?, ?)",
                binds: { statement in
                    sqlite3_bind_text(statement, 1, friend.name, -1, databaseTransientDestructor)
                    sqlite3_bind_text(statement, 2, friend.ipAddress, -1, databaseTransientDestructor)
                    sqlite3_bind_int(statement, 3, Int32(friend.port))
                    sqlite3_bind_int(statement, 4, friend.sendAll ? 1 : 0)
                }
            )
            return sqlite3_last_insert_rowid(database)
        } else {
            try execute(
                "UPDATE Friends SET name = ?, ipAddress = ?, port = ?, sendAll = ? WHERE id = ?",
                binds: { statement in
                    sqlite3_bind_text(statement, 1, friend.name, -1, databaseTransientDestructor)
                    sqlite3_bind_text(statement, 2, friend.ipAddress, -1, databaseTransientDestructor)
                    sqlite3_bind_int(statement, 3, Int32(friend.port))
                    sqlite3_bind_int(statement, 4, friend.sendAll ? 1 : 0)
                    sqlite3_bind_int64(statement, 5, friend.id)
                }
            )
            return friend.id
        }
    }

    func deleteFriend(id: Int64) throws {
        try execute("DELETE FROM Friends WHERE id = ?", binds: { sqlite3_bind_int64($0, 1, id) })
    }

    // MARK: - Export archive

    func exportArchive(entries: [ClipboardEntry], groups: [ClipGroup], to url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        let archiveDatabase = try MacClipboardDatabase(url: url, useWAL: false)
        for entry in entries {
            for key in [entry.rtfBlobKey, entry.htmlBlobKey, entry.imageBlobKey, entry.pdfBlobKey].compactMap({ $0 }) {
                guard let data = blobData(key: key) else { continue }
                _ = try archiveDatabase.saveBlob(data, key: key, fileExtension: URL(fileURLWithPath: key).pathExtension)
            }
        }
        try archiveDatabase.replaceEntries(entries)
        try archiveDatabase.replaceGroups(groups)
    }

    // MARK: - SQL helpers

    private func transaction(_ body: () throws -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            _ = try? execute("ROLLBACK")
            throw error
        }
    }

    @discardableResult
    private func execute(_ sql: String, binds: ((OpaquePointer?) -> Void)? = nil) throws -> Int {
        try query(sql, binds: binds) { statement in
            let result = sqlite3_step(statement)
            guard result == SQLITE_DONE || result == SQLITE_ROW else {
                let message = database.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? sql
                throw MacClipboardDatabaseError.executeFailed(message)
            }
            return Int(sqlite3_changes(database))
        }
    }

    private func query<T>(
        _ sql: String,
        binds: ((OpaquePointer?) -> Void)? = nil,
        body: (OpaquePointer?) throws -> T
    ) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            let message = database.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? sql
            throw MacClipboardDatabaseError.prepareFailed(message)
        }
        defer { sqlite3_finalize(statement) }
        binds?(statement)
        return try body(statement)
    }

    private func bindOptionalText(_ statement: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(statement, index, value, -1, databaseTransientDestructor)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private static func optionalString(_ statement: OpaquePointer?, _ column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return string(statement, column)
    }

    private static func string(_ statement: OpaquePointer?, _ column: Int32) -> String {
        guard let value = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: value)
    }

    private static func optionalInt64(_ statement: OpaquePointer?, _ column: Int32) -> Int64? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return sqlite3_column_int64(statement, column)
    }

    private static func optionalBool(_ statement: OpaquePointer?, _ column: Int32) -> Bool? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return sqlite3_column_int(statement, column) != 0
    }

    private static func optionalDate(_ statement: OpaquePointer?, _ column: Int32) -> Date? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(statement, column))
    }

    private static func bindOptionalBool(_ statement: OpaquePointer?, _ index: Int32, _ value: Bool?) {
        if let value {
            sqlite3_bind_int(statement, index, value ? 1 : 0)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private static func bindOptionalDate(_ statement: OpaquePointer?, _ index: Int32, _ value: Date?) {
        if let value {
            sqlite3_bind_double(statement, index, value.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private static func bindOptionalInt64(_ statement: OpaquePointer?, _ index: Int32, _ value: Int64?) {
        if let value {
            sqlite3_bind_int64(statement, index, value)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private static func blob(_ statement: OpaquePointer?, _ column: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(statement, column) else { return nil }
        let count = Int(sqlite3_column_bytes(statement, column))
        return Data(bytes: bytes, count: count)
    }
}

private let databaseTransientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
