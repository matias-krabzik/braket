import CryptoKit
import Foundation
import SQLite3

struct SQLHistoryEntry: Identifiable, Sendable {
    let id: Int64
    let date: Date
    let sql: String
    let connection: String
    let database: String
    let source: String
    let status: String
    let elapsed: Double
    let rows: Int64
    let affected: String
    let error: String

    var statusLabel: String {
        switch status {
        case "running": "Ejecutando"
        case "success": "Correcta"
        case "cancelled": "Cancelada"
        case "timeout": "Tiempo agotado"
        case "interrupted": "Interrumpida"
        default: "Error"
        }
    }
}

/// One database per canonical project path. SQLite and its handles stay off the main actor.
actor SQLHistoryStore {
    nonisolated let url: URL
    private var connection: SQLHistoryDatabase?
    private(set) var revision = 0
    private(set) var writeError: String?

    nonisolated static func fileURL(project: URL, root: URL? = nil) -> URL {
        let path = project.resolvingSymlinksInPath().standardizedFileURL.path
        let digest = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        let directory = root ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Braket/QueryHistory", isDirectory: true)
        return directory.appendingPathComponent(digest, isDirectory: true).appendingPathComponent("output.sqlite")
    }

    init(url: URL) { self.url = url }

    private func database() throws -> SQLHistoryDatabase {
        if let connection { return connection }
        let opened = try SQLHistoryDatabase(url: url)
        connection = opened
        return opened
    }

    func begin(sql: String, configuration: DatabaseConnection, database name: String, source: String) -> UUID {
        let token = UUID()
        do {
            try database().execute("""
            INSERT INTO executions(token, timestamp, sql, connection_id, connection_name, database_name, source, status)
            VALUES (?, ?, ?, ?, ?, ?, ?, 'running')
            """, [token.uuidString, String(Date().timeIntervalSince1970), sql, configuration.id.uuidString,
                  configuration.name, name, source])
            revision += 1
        } catch { report(error) }
        return token
    }

    func finish(_ token: UUID, status: String, elapsed: Double, rows: Int = 0, affected: UInt64 = 0, error: String = "") {
        do {
            try database().execute("""
            UPDATE executions SET status = ?, elapsed = ?, rows = ?, affected = ?, error = ? WHERE token = ?
            """, [status, String(elapsed), String(rows), String(affected), error, token.uuidString])
            revision += 1
        } catch { report(error) }
    }

    private func report(_ error: Error) {
        writeError = "No se pudo guardar el historial: " + error.localizedDescription
        Log.mysql.error("No se pudo guardar el historial SQL: \(error.localizedDescription, privacy: .private)")
    }

    /// Keyset pagination remains stable when new queries arrive while browsing older pages.
    func page(search: String = "", before: Int64? = nil, limit: Int = 200) throws -> [SQLHistoryEntry] {
        let terms = search.split { !$0.isLetter && !$0.isNumber && $0 != "_" }
        var predicate = "id < ?"
        var values = [String(before ?? Int64.max)]
        if !terms.isEmpty {
            predicate += " AND id IN (SELECT rowid FROM executions_fts WHERE executions_fts MATCH ?)"
            values.append(terms.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"*" }.joined(separator: " AND "))
        }
        values.append(String(max(1, min(limit, 201))))
        return try database().entries(where: predicate, values: values, fullText: false)
    }

    func detail(_ id: Int64) throws -> SQLHistoryEntry? {
        try database().entries(where: "id = ?", values: [String(id), "1"], fullText: true).first
    }

    func close() { connection = nil }
}

/// Owned exclusively by SQLHistoryStore; finalizes every statement before closing the handle.
private final class SQLHistoryDatabase {
    private let handle: OpaquePointer

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var opened: OpaquePointer?
        let code = sqlite3_open_v2(url.path, &opened, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard code == SQLITE_OK, let opened else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "No se pudo abrir SQLite."
            if let opened { sqlite3_close(opened) }
            throw DatabaseFailure(message)
        }
        handle = opened
        do {
            sqlite3_busy_timeout(handle, 3000)
            try execute("PRAGMA journal_mode = WAL")
            try execute("PRAGMA synchronous = FULL")
            try execute("BEGIN IMMEDIATE")
            try execute("""
            CREATE TABLE IF NOT EXISTS executions (
                id INTEGER PRIMARY KEY AUTOINCREMENT, token TEXT NOT NULL UNIQUE, timestamp REAL NOT NULL,
                sql TEXT NOT NULL, connection_id TEXT NOT NULL, connection_name TEXT NOT NULL,
                database_name TEXT NOT NULL, source TEXT NOT NULL, status TEXT NOT NULL,
                elapsed REAL NOT NULL DEFAULT 0, rows INTEGER NOT NULL DEFAULT 0,
                affected TEXT NOT NULL DEFAULT '0', error TEXT NOT NULL DEFAULT ''
            )
            """)
            try execute("CREATE INDEX IF NOT EXISTS executions_date ON executions(timestamp DESC)")
            try execute("CREATE INDEX IF NOT EXISTS executions_connection ON executions(connection_id, id DESC)")
            try execute("CREATE INDEX IF NOT EXISTS executions_status ON executions(status, id DESC)")
            try execute("""
            CREATE VIRTUAL TABLE IF NOT EXISTS executions_fts USING fts5(
                sql, connection_name, database_name, content='executions', content_rowid='id', prefix='2 3 4'
            )
            """)
            try execute("""
            CREATE TRIGGER IF NOT EXISTS executions_insert AFTER INSERT ON executions BEGIN
                INSERT INTO executions_fts(rowid, sql, connection_name, database_name)
                VALUES (new.id, new.sql, new.connection_name, new.database_name);
            END
            """)
            // A previous process ended before receiving the server's final response.
            try execute("""
            UPDATE executions SET status = 'interrupted', error = 'La app se cerró sin recibir el resultado final.'
            WHERE status = 'running'
            """)
            try execute("PRAGMA user_version = 1")
            try execute("COMMIT")
        } catch {
            sqlite3_exec(handle, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    deinit { sqlite3_close(handle) }

    private func prepare(_ sql: String, _ values: [String]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure() }
        for (index, value) in values.enumerated() {
            let code = value.withCString {
                sqlite3_bind_text(statement, Int32(index + 1), $0, Int32(value.utf8.count),
                                  unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
            if code != SQLITE_OK {
                sqlite3_finalize(statement)
                throw failure()
            }
        }
        return statement
    }

    func execute(_ sql: String, _ values: [String] = []) throws {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        var code = sqlite3_step(statement)
        while code == SQLITE_ROW { code = sqlite3_step(statement) }
        guard code == SQLITE_DONE else { throw failure() }
    }

    func entries(where predicate: String, values: [String], fullText: Bool) throws -> [SQLHistoryEntry] {
        let sql = fullText ? "sql" : "substr(sql, 1, 400)"
        let statement = try prepare("""
        SELECT id, timestamp, \(sql), connection_name, database_name, source, status, elapsed, rows, affected, error
        FROM executions WHERE \(predicate) ORDER BY id DESC LIMIT ?
        """, values)
        defer { sqlite3_finalize(statement) }
        var entries: [SQLHistoryEntry] = []
        var code = sqlite3_step(statement)
        while code == SQLITE_ROW {
            func text(_ column: Int32) -> String {
                guard let pointer = sqlite3_column_text(statement, column) else { return "" }
                return String(decoding: UnsafeBufferPointer(start: pointer, count: Int(sqlite3_column_bytes(statement, column))),
                              as: UTF8.self)
            }
            entries.append(SQLHistoryEntry(id: sqlite3_column_int64(statement, 0),
                                           date: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)), sql: text(2),
                                           connection: text(3), database: text(4), source: text(5), status: text(6),
                                           elapsed: sqlite3_column_double(statement, 7), rows: sqlite3_column_int64(statement, 8),
                                           affected: text(9), error: text(10)))
            code = sqlite3_step(statement)
        }
        guard code == SQLITE_DONE else { throw failure() }
        return entries
    }

    private func failure() -> DatabaseFailure { DatabaseFailure(String(cString: sqlite3_errmsg(handle))) }
}
