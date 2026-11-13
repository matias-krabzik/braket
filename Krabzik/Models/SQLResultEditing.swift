import AppKit
import Observation

enum SQLCellValue: Equatable, Sendable {
    case text(String), null, serverDefault
    var display: String {
        switch self { case .text(let text): text
        case .null: "NULL"
        case .serverDefault: "DEFAULT" }
    }
    var sql: String {
        switch self { case .text(let text): SQLValue.literal(text)
        case .null: "NULL"
        case .serverDefault: "DEFAULT" }
    }
}

struct SQLCell: Hashable, Sendable { var row: Int
var column: Int }
struct SQLMutation: Sendable {
    var sql: String
    var verificationSQL: String?
    var allowsUnchanged = false
}

@MainActor @Observable
final class SQLResultDraft {
    let result: SQLResult
    var table: SQLSchemaTable?
    var reason = "Cargando estructura…"
    var changes: [SQLCell: SQLCellValue] = [:]
    var inserted: [[SQLCellValue]] = []
    var deleted: Set<Int> = []
    var showingReview = false
    var sending = false
    var sent = false
    var error: String?
    var widths: [Int: CGFloat] = [:]
    var hasChanges: Bool { !changes.isEmpty || !inserted.isEmpty || !deleted.isEmpty }
    var rowCount: Int { result.rows.count + inserted.count }
    var canEdit: Bool { table != nil && reason.isEmpty && !sending && !sent }
    var canInsert: Bool {
        guard canEdit, let table else { return false }
        let names = Set(result.origins.map(\.column))
        return table.columns.allSatisfy { names.contains($0.name) || $0.canDefault }
    }

    init(result: SQLResult) { self.result = result }

    func configure(_ schema: SQLSchemaTable?) {
        guard !hasChanges, !sent else { return }
        table = schema
        reason = Self.readOnlyReason(result, table: schema) ?? ""
    }

    static func readOnlyReason(_ result: SQLResult, table: SQLSchemaTable?) -> String? {
        guard !result.origins.isEmpty, result.origins.allSatisfy({ !$0.table.isEmpty && !$0.column.isEmpty }) else {
            return "Solo lectura: resultado calculado o sin tabla de origen."
        }
        guard let table else { return "Solo lectura: estructura no disponible. Actualizá las bases de la conexión." }
        guard table.kind == "BASE TABLE", table.engine.uppercased() == "INNODB" else {
            return "Solo lectura: la edición transaccional requiere una tabla InnoDB."
        }
        guard !result.truncated, result.error == nil else { return "Solo lectura: resultado incompleto." }
        guard !result.origins.isEmpty, result.origins.count == result.columns.count,
              result.origins.allSatisfy({ $0.database == table.database && $0.table == table.name && !$0.column.isEmpty && !$0.binary }),
              Set(result.origins.map(\.column)).count == result.columns.count else {
            return "Solo lectura: hay expresiones, columnas binarias o varias tablas de origen."
        }
        // Restrict editing to a direct SELECT. Fail closed for joins, subqueries and aggregate/grouped results.
        let sql = result.sql.uppercased()
        guard sql.range(of: #"^\s*SELECT\s"#, options: .regularExpression) != nil,
              sql.range(of: #"\b(JOIN|UNION|GROUP|DISTINCT|HAVING|PROCEDURE|INTO)\b|\(\s*SELECT\b"#,
                        options: .regularExpression) == nil else {
            return "Solo lectura: usá un SELECT directo de una sola tabla."
        }
        let names = result.origins.map(\.column)
        guard let key = table.uniqueKeys.first(where: { key in
            !key.isEmpty && key.allSatisfy { name in names.contains(name) && table.columns.contains { $0.name == name && !$0.nullable } }
        }) else { return "Solo lectura: incluí una clave primaria o única no nullable en la consulta." }
        let indices = key.compactMap { names.firstIndex(of: $0) }
        var seen = Set<[String]>()
        for row in result.rows {
            let identity = indices.compactMap { row[$0] }
            guard identity.count == indices.count, seen.insert(identity).inserted else {
                return "Solo lectura: las filas no tienen una identidad única."
            }
        }
        return nil
    }

    func column(_ index: Int) -> SQLSchemaColumn? {
        guard result.origins.indices.contains(index) else { return nil }
        return table?.columns.first { $0.name == result.origins[index].column }
    }

    func value(row: Int, column: Int) -> SQLCellValue {
        if row >= result.rows.count { return inserted[row - result.rows.count][column] }
        if let changed = changes[SQLCell(row: row, column: column)] { return changed }
        return result.rows[row][column].map(SQLCellValue.text) ?? .null
    }

    func set(_ value: SQLCellValue, row: Int, column: Int) {
        guard canEdit, !deleted.contains(row), let metadata = self.column(column), !metadata.generated else { return }
        if value == .null && !metadata.nullable { return }
        if value == .serverDefault && !metadata.canDefault { return }
        if row >= result.rows.count { inserted[row - result.rows.count][column] = value
        return }
        let cell = SQLCell(row: row, column: column)
        let original = result.rows[row][column].map(SQLCellValue.text) ?? .null
        if value == original { changes.removeValue(forKey: cell) } else { changes[cell] = value }
    }

    func addRow(duplicating row: Int? = nil) {
        guard canInsert else { return }
        inserted.append(result.columns.indices.map { index in
            let metadata = column(index)
            if metadata?.autoIncrement == true || metadata?.generated == true { return .serverDefault }
            if let row { return value(row: row, column: index) }
            return metadata?.canDefault == true ? .serverDefault : .text("")
        })
    }

    func deleteRow(_ row: Int) {
        guard canEdit else { return }
        if row >= result.rows.count { inserted.remove(at: row - result.rows.count) }
        else if deleted.contains(row) { deleted.remove(row) }
        else { deleted.insert(row) }
    }

    func discard() { changes = [:]
    inserted = []
    deleted = []
    error = nil }

    func mutations() throws -> [SQLMutation] {
        guard canEdit, let table else { throw DatabaseFailure(reason.isEmpty ? "El resultado necesita actualizarse." : reason) }
        var output: [SQLMutation] = []
        for row in result.rows.indices {
            let predicate = result.origins.enumerated().map { index, origin in
                "CAST(" + SQLValue.identifier(origin.column) + " AS BINARY) <=> CAST("
                    + SQLValue.literal(result.rows[row][index]) + " AS BINARY)"
            }.joined(separator: " AND ")
            if deleted.contains(row) {
                output.append(SQLMutation(sql: "DELETE FROM " + table.qualified + " WHERE " + predicate + " LIMIT 1",
                                          verificationSQL: "SELECT 1 FROM " + table.qualified + " WHERE " + predicate
                                                  + " LIMIT 1 FOR UPDATE"))
            } else {
                let assignments = result.columns.indices.compactMap { index -> String? in
                    guard let value = changes[SQLCell(row: row, column: index)] else { return nil }
                    return SQLValue.identifier(result.origins[index].column) + " = " + value.sql
                }
                if !assignments.isEmpty {
                    output.append(SQLMutation(sql: "UPDATE " + table.qualified + " SET " + assignments.joined(separator: ", ")
                                              + " WHERE " + predicate + " LIMIT 1",
                                              verificationSQL: "SELECT 1 FROM " + table.qualified + " WHERE " + predicate
                                                  + " LIMIT 1 FOR UPDATE", allowsUnchanged: true))
                }
            }
        }
        for row in inserted {
            let indices = result.columns.indices.filter { column($0)?.generated != true }
            output.append(SQLMutation(sql: "INSERT INTO " + table.qualified + " ("
                                      + indices.map { SQLValue.identifier(result.origins[$0].column) }.joined(separator: ", ")
                                      + ") VALUES (" + indices.map { row[$0].sql }.joined(separator: ", ") + ")"))
        }
        return output
    }

    func confirmDiscard() -> Bool {
        guard hasChanges else { return true }
        let alert = NSAlert()
        alert.messageText = "¿Descartar los cambios pendientes de este resultado?"
        alert.informativeText = "Todavía no se enviaron a la base de datos."
        alert.addButton(withTitle: "Descartar")
        alert.addButton(withTitle: "Cancelar")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
