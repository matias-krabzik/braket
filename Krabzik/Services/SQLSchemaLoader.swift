import Foundation

struct SQLSchemaProgress: Sendable {
    var database: String
    var message: String
    var tables: [SQLSchemaTable]?
}

/// Bounded pages per database avoid two network round trips for every table.
struct SQLSchemaLoader: Sendable {
    let read: @Sendable (String) async throws -> SQLResult
    private let pageSize = 500

    func load(connection: DatabaseConnection, databases: [String],
              progress: @escaping @Sendable (SQLSchemaProgress) async -> Void) async throws -> SQLSchemaSnapshot {
        var allTables: [SQLSchemaTable] = []
        for database in databases {
            try Task.checkCancellation()
            let predicate = " WHERE TABLE_SCHEMA = " + SQLValue.literal(database)
            await progress(.init(database: database, message: "Leyendo tablas de \(database)…"))
            let rows = try await pages("SELECT TABLE_NAME, TABLE_TYPE, ENGINE FROM INFORMATION_SCHEMA.TABLES"
                                       + predicate + " ORDER BY TABLE_NAME")
            var tables = rows.compactMap { row -> SQLSchemaTable? in
                guard row.count == 3, let name = row[0] else { return nil }
                return SQLSchemaTable(database: database, name: name, kind: row[1] ?? "", engine: row[2] ?? "",
                                      metadataComplete: false)
            }
            await progress(.init(database: database, message: "\(database): \(tables.count) tablas. Leyendo columnas…", tables: tables))
            let columns = try await pages("SELECT TABLE_NAME, COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE, COLUMN_DEFAULT, EXTRA "
                                          + "FROM INFORMATION_SCHEMA.COLUMNS" + predicate + " ORDER BY TABLE_NAME, ORDINAL_POSITION")
            var byTable: [String: [SQLSchemaColumn]] = [:]
            for row in columns where row.count == 6 {
                guard let table = row[0], let name = row[1], let type = row[2] else { continue }
                byTable[table, default: []].append(SQLSchemaColumn(name: name, type: type, nullable: row[3] == "YES",
                                                                   defaultValue: row[4], extra: row[5] ?? ""))
            }
            for index in tables.indices { tables[index].columns = byTable[tables[index].name] ?? [] }
            await progress(.init(database: database, message: "\(database): columnas listas. Leyendo claves…", tables: tables))
            let keys = try await pages("SELECT TABLE_NAME, INDEX_NAME, COLUMN_NAME FROM INFORMATION_SCHEMA.STATISTICS"
                                       + predicate + " AND NON_UNIQUE = 0 ORDER BY TABLE_NAME, INDEX_NAME, SEQ_IN_INDEX")
            var grouped: [String: [String: [String]]] = [:]
            var invalid: [String: Set<String>] = [:]
            for row in keys where row.count == 3 {
                guard let table = row[0], let name = row[1] else { continue }
                if let column = row[2] { grouped[table, default: [:]][name, default: []].append(column) }
                else { invalid[table, default: []].insert(name) }
            }
            for index in tables.indices {
                let table = tables[index].name
                let indices = grouped[table] ?? [:]
                tables[index].metadataComplete = true
                tables[index].uniqueKeys = indices.keys.sorted().filter { invalid[table]?.contains($0) != true }
                    .compactMap { indices[$0] }
            }
            allTables += tables
            await progress(.init(database: database, message: "\(database): estructura cargada.", tables: tables))
        }
        try Task.checkCancellation()
        return SQLSchemaSnapshot(connection: connection, databases: databases, tables: allTables, isPartial: false)
    }

    private func pages(_ sql: String) async throws -> [[String?]] {
        var rows: [[String?]] = []
        while true {
            try Task.checkCancellation()
            let result = try await read(sql + " LIMIT \(pageSize) OFFSET \(rows.count)")
            guard !result.truncated else { throw DatabaseFailure("Una página de la estructura llegó incompleta. Reintentá la carga.") }
            rows += result.rows
            if result.rows.count < pageSize { return rows }
            guard rows.count < 100_000 else {
                throw DatabaseFailure("La base supera el límite de 100.000 elementos de estructura. Se conserva lo leído hasta ahora.")
            }
        }
    }
}
