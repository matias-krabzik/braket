import Foundation

struct SQLTableIdentity: Hashable, Sendable {
    let database: String
    let table: String
}

struct SQLForeignKey: Codable, Equatable, Sendable {
    let name: String
    let columns: [String]
    let columnTypes: [String]
    let database: String
    let table: String
    let referencedColumns: [String]

    static func query(database: String, table: String? = nil) -> String {
        "SELECT k.TABLE_NAME, k.CONSTRAINT_NAME, k.COLUMN_NAME, k.REFERENCED_TABLE_SCHEMA, "
            + "k.REFERENCED_TABLE_NAME, k.REFERENCED_COLUMN_NAME, c.COLUMN_TYPE "
            + "FROM INFORMATION_SCHEMA.KEY_COLUMN_USAGE k JOIN INFORMATION_SCHEMA.COLUMNS c "
            + "ON c.TABLE_SCHEMA = k.TABLE_SCHEMA AND c.TABLE_NAME = k.TABLE_NAME AND c.COLUMN_NAME = k.COLUMN_NAME "
            + "WHERE k.TABLE_SCHEMA = " + SQLValue.literal(database)
            + (table.map { " AND k.TABLE_NAME = " + SQLValue.literal($0) } ?? "")
            + " AND k.REFERENCED_TABLE_NAME IS NOT NULL ORDER BY k.TABLE_NAME, k.CONSTRAINT_NAME, k.ORDINAL_POSITION"
    }

    static func grouped(_ rows: [[String?]]) -> [String: [SQLForeignKey]] {
        var groups: [String: [String: [[String]]]] = [:]
        var invalid: [String: Set<String>] = [:]
        for row in rows {
            guard row.count >= 2, let table = row[0], let constraint = row[1] else { continue }
            let values = row.compactMap { $0 }
            guard row.count == 7, values.count == 7 else { invalid[table, default: []].insert(constraint)
            continue }
            groups[values[0], default: [:]][values[1], default: []].append(values)
        }
        return groups.mapValues { constraints in
            constraints.keys.sorted().compactMap { name in
                guard let rows = constraints[name], let first = rows.first, invalid[first[0]]?.contains(name) != true,
                      rows.allSatisfy({ $0[3] == first[3] && $0[4] == first[4] }) else { return nil }
                return SQLForeignKey(name: name, columns: rows.map { $0[2] }, columnTypes: rows.map { $0[6] },
                                     database: first[3], table: first[4], referencedColumns: rows.map { $0[5] })
            }
        }
    }
}

struct SQLRelatedTarget: Equatable, Sendable {
    let source: SQLTableIdentity
    let key: SQLForeignKey
    let values: [String]
    var label: String { key.columns.joined(separator: ", ") + " → " + key.table + "." + key.referencedColumns.joined(separator: ", ") }
    var query: String { select + ";" }
    var previewQuery: String { select + " LIMIT 100;" }
    private var select: String {
        let predicates = zip(key.referencedColumns.indices, values).map { index, value in
            let column = SQLSchemaColumn(name: key.columns[index], type: key.columnTypes[index], nullable: true, extra: "")
            return SQLValue.identifier(key.referencedColumns[index]) + " = " + SQLValue.keyLiteral(value, column: column)
        }
        return "SELECT * FROM " + SQLValue.identifier(key.database) + "." + SQLValue.identifier(key.table)
            + " WHERE " + predicates.joined(separator: " AND ")
    }
}
