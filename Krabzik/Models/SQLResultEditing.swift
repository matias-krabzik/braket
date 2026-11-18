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
    var originalRow: [String?]?

    /// String == normaliza Unicode. La comprobación de conflictos debe comparar bytes exactos.
    func matchesOriginal(_ rows: [[String?]]) -> Bool {
        guard let originalRow, rows.count == 1, let row = rows.first, row.count == originalRow.count else { return false }
        return zip(row, originalRow).allSatisfy { current, original in
            switch (current, original) {
            case (nil, nil): return true
            case let (current?, original?): return current.utf8.elementsEqual(original.utf8)
            default: return false
            }
        }
    }
}

@MainActor @Observable
final class SQLResultDraft {
    let result: SQLResult
    var table: SQLSchemaTable?
    var reason = "Cargando estructura…"
    var changes: [SQLCell: SQLCellValue] = [:]
    var inserted: [[SQLCellValue]] = []
    private var insertedOriginals: [[SQLCellValue]] = []
    var selectedCell: SQLCell?
    var scrollOrigin: NSPoint = .zero
    var isEditingCell = false
    var canDeleteSelected: Bool {
        guard let cell = selectedCell else { return false }
        return canEdit && !isEditingCell && (0..<rowCount).contains(cell.row) && !deleted.contains(cell.row)
    }
    var canResetSelected: Bool {
        guard canEdit, !isEditingCell, let cell = selectedCell,
              (0..<rowCount).contains(cell.row), !deleted.contains(cell.row) else { return false }
        if cell.row < result.rows.count { return changes[cell] != nil }
        let row = cell.row - result.rows.count
        return inserted[row][cell.column] != insertedOriginals[row][cell.column]
    }

    func resetSelected() {
        guard canResetSelected, let cell = selectedCell else { return }
        if cell.row < result.rows.count { changes.removeValue(forKey: cell) }
        else { inserted[cell.row - result.rows.count][cell.column] = insertedOriginals[cell.row - result.rows.count][cell.column] }
        QAProbe.action("grid.reset", qaFields)
    }

    /// Si esta celda se puede poner en modo edición. Es la condición que la grilla
    /// consulta antes de abrir el campo, y la que una prueba afirma antes de escribir.
    func canEditCell(row: Int, column: Int) -> Bool {
        canEdit && row >= 0 && column >= 0 && column < result.columns.count && row < rowCount && !deleted.contains(row)
            && self.column(column)?.generated != true
    }

    /// Entra en modo edición en una celda. La grilla de AppKit llama acá para la parte
    /// de modelo y después abre el campo; un escenario de QA llama acá y escribe con
    /// `endEditing(commit:)`. Un solo sitio decide si la celda es editable.
    @discardableResult
    func beginEditing(row: Int, column: Int) -> Bool {
        guard canEditCell(row: row, column: column) else {
            QAProbe.sql("grid.edit.denied", ["row": QAField.count(row), "column": QAField.count(column),
                                             "reason": QAField.text(reason.isEmpty ? "celda no editable" : reason)])
            return false
        }
        selectedCell = SQLCell(row: row, column: column)
        isEditingCell = true
        QAProbe.action("grid.edit.begin", ["row": QAField.count(row), "column": QAField.count(column),
                                           "value": QAField.text(value(row: row, column: column).display)])
        QAProbe.state("state.draft", qaFields)
        return true
    }

    /// Sale del modo edición. Con `commit` guarda el valor en la celda que se estaba
    /// editando; sin él, descarta lo tecleado y deja la celda como estaba.
    func endEditing(commit committed: SQLCellValue? = nil) {
        let cell = selectedCell
        isEditingCell = false
        if let committed, let cell { set(committed, row: cell.row, column: cell.column) }
        QAProbe.action("grid.edit.end", ["committed": QAField.bool(committed != nil),
                                         "row": QAField.count(cell?.row ?? -1),
                                         "column": QAField.count(cell?.column ?? -1),
                                         "value": QAField.text(committed?.display ?? "")])
        QAProbe.state("state.draft", qaFields)
    }

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
        QAProbe.state("state.draft", qaFields)
    }

    static func readOnlyReason(_ result: SQLResult, table: SQLSchemaTable?) -> String? {
        // La política del perfil manda sobre todo lo demás: ver S8.
        if let connection = result.connection, connection.effectiveWritePolicy == .readOnly {
            return "Solo lectura: el perfil «\(connection.name)» no permite escrituras."
        }
        guard !result.origins.isEmpty, result.origins.allSatisfy({ !$0.table.isEmpty && !$0.column.isEmpty }) else {
            return "Solo lectura: resultado calculado o sin tabla de origen."
        }
        guard let table else { return "Solo lectura: estructura no disponible. Actualizá las bases de la conexión." }
        guard table.metadataComplete != false else { return "Solo lectura: falta completar la estructura de esta tabla." }
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
        guard let key = table.editingKey(in: Set(names)) else {
            return "Solo lectura: incluí la clave primaria completa o, si no existe, una clave única no nullable."
        }
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
        guard canEdit, !deleted.contains(row), let metadata = self.column(column), !metadata.generated else {
            QAProbe.sql("grid.set.denied", ["row": QAField.count(row), "column": QAField.count(column),
                                            "reason": QAField.text(reason.isEmpty ? "columna no editable" : reason)])
            return
        }
        if value == .null && !metadata.nullable {
            QAProbe.sql("grid.set.denied", ["row": QAField.count(row), "column": QAField.count(column),
                                            "reason": "la columna no admite NULL"])
            return
        }
        if value == .serverDefault && !metadata.canDefault {
            QAProbe.sql("grid.set.denied", ["row": QAField.count(row), "column": QAField.count(column),
                                            "reason": "la columna no tiene DEFAULT"])
            return
        }
        defer { QAProbe.state("state.draft", qaFields) }
        if row >= result.rows.count { inserted[row - result.rows.count][column] = value
        return }
        let cell = SQLCell(row: row, column: column)
        let original = result.rows[row][column].map(SQLCellValue.text) ?? .null
        if value == original { changes.removeValue(forKey: cell) } else { changes[cell] = value }
    }

    func addRow(duplicating row: Int? = nil) {
        guard canInsert else {
            QAProbe.sql("grid.addRow.denied", ["reason": QAField.text(reason.isEmpty ? "falta una columna con DEFAULT" : reason)])
            return
        }
        defer { QAProbe.state("state.draft", qaFields) }
        QAProbe.action("grid.addRow", ["duplicating": QAField.count(row ?? -1)])
        inserted.append(result.columns.indices.map { index in
            let metadata = column(index)
            if metadata?.autoIncrement == true || metadata?.generated == true { return .serverDefault }
            if let row { return value(row: row, column: index) }
            return metadata?.canDefault == true ? .serverDefault : .text("")
        })
        insertedOriginals.append(inserted[inserted.count - 1])
        selectedCell = SQLCell(row: rowCount - 1, column: 0)
    }

    func deleteRow(_ row: Int) {
        guard canEdit, (0..<rowCount).contains(row) else {
            QAProbe.sql("grid.deleteRow.denied", ["row": QAField.count(row),
                                                  "reason": QAField.text(reason.isEmpty ? "fila fuera de rango" : reason)])
            return
        }
        defer {
            QAProbe.action("grid.deleteRow", ["row": QAField.count(row)])
            QAProbe.state("state.draft", qaFields)
        }
        if row >= result.rows.count {
            inserted.remove(at: row - result.rows.count)
            insertedOriginals.remove(at: row - result.rows.count)
            selectedCell = nil
        }
        else if deleted.contains(row) { deleted.remove(row) }
        else { deleted.insert(row) }
    }

    func discard() { QAProbe.action("grid.discard", qaFields)
    changes = [:]
    inserted = []
    insertedOriginals = []
    selectedCell = nil
    deleted = []
    error = nil }

    func mutations() throws -> [SQLMutation] {
        guard canEdit, let table else { throw DatabaseFailure(reason.isEmpty ? "El resultado necesita actualizarse." : reason) }
        var output: [SQLMutation] = []
        guard let key = table.editingKey(in: Set(result.origins.map(\.column))) else {
            throw DatabaseFailure("No hay una clave completa para identificar la fila.")
        }
        let columns = result.origins.map { SQLValue.identifier($0.column) }.joined(separator: ", ")
        for row in result.rows.indices {
            let assignments = result.columns.indices.compactMap { index -> String? in
                guard let value = changes[SQLCell(row: row, column: index)] else { return nil }
                return SQLValue.identifier(result.origins[index].column) + " = " + value.sql
            }
            guard deleted.contains(row) || !assignments.isEmpty else { continue }
            let predicate = try key.map { name -> String in
                guard let index = result.origins.firstIndex(where: { $0.column == name }),
                      let value = result.rows[row][index] else { throw DatabaseFailure("La clave de la fila está incompleta.") }
                let metadata = table.columns.first { $0.name == name }
                return SQLValue.identifier(name) + " = " + SQLValue.keyLiteral(value, column: metadata)
            }.joined(separator: " AND ")
            let verification = "SELECT " + columns + " FROM " + table.qualified + " WHERE " + predicate + " LIMIT 2 FOR UPDATE"
            let sql = deleted.contains(row) ? "DELETE FROM " + table.qualified + " WHERE " + predicate + " LIMIT 1"
                : "UPDATE " + table.qualified + " SET " + assignments.joined(separator: ", ") + " WHERE " + predicate + " LIMIT 1"
            output.append(SQLMutation(sql: sql, verificationSQL: verification, allowsUnchanged: !deleted.contains(row),
                                      originalRow: result.rows[row]))
        }
        for row in inserted {
            let indices = result.columns.indices.filter { column($0)?.generated != true }
            output.append(SQLMutation(sql: "INSERT INTO " + table.qualified + " ("
                                      + indices.map { SQLValue.identifier(result.origins[$0].column) }.joined(separator: ", ")
                                      + ") VALUES (" + indices.map { row[$0].sql }.joined(separator: ", ") + ")"))
        }
        return output
    }

    /// Cómo se pregunta antes de perder cambios que no se enviaron. Punto de inyección
    /// por el mismo motivo que `DatabaseController.askBeforeWriting`: el `NSAlert` real
    /// cuelga una corrida de pruebas. El diálogo se arma en `discardAlert()`.
    @MainActor
    static var confirmDiscardChanges: (SQLResultDraft) -> Bool = { draft in
        draft.discardAlert().runModal() == .alertFirstButtonReturn
    }

    func confirmDiscard() -> Bool {
        guard hasChanges else { return true }
        let confirmed = Self.confirmDiscardChanges(self)
        QAProbe.dialog("dialog.grid.discardChanges", answer: confirmed ? "discard" : "cancel",
                       ["changes": QAField.count(changes.count), "inserted": QAField.count(inserted.count),
                        "deleted": QAField.count(deleted.count)])
        return confirmed
    }

    func discardAlert() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "¿Descartar los cambios pendientes de este resultado?"
        alert.informativeText = "Todavía no se enviaron a la base de datos."
        alert.addButton(withTitle: "Descartar")
        alert.addButton(withTitle: "Cancelar")
        return alert
    }
}
