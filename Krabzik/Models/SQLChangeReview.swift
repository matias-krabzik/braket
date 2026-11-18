import Foundation

struct SQLFieldChange: Identifiable, Sendable {
    let name: String
    let before: SQLCellValue?
    let after: SQLCellValue?
    var id: String { name }
}

struct SQLRowChange: Identifiable, Sendable {
    let row: Int
    let action: String
    let identity: String
    let fields: [SQLFieldChange]
    var id: Int { row }
}

extension SQLResultDraft {
    var reviewChanges: [SQLRowChange] {
        var rows: [SQLRowChange] = []
        let key = table?.editingKey(in: Set(result.origins.map(\.column))) ?? []
        for row in result.rows.indices {
            let removing = deleted.contains(row)
            let fields = result.columns.indices.compactMap { column -> SQLFieldChange? in
                let before = result.rows[row][column].map(SQLCellValue.text) ?? .null
                if removing { return SQLFieldChange(name: result.origins[column].column, before: before, after: nil) }
                guard let after = changes[SQLCell(row: row, column: column)] else { return nil }
                return SQLFieldChange(name: result.origins[column].column, before: before, after: after)
            }
            guard !fields.isEmpty else { continue }
            let identity = key.compactMap { name -> String? in
                guard let column = result.origins.firstIndex(where: { $0.column == name }) else { return nil }
                return name + " = " + (result.rows[row][column] ?? "NULL")
            }.joined(separator: ", ")
            rows.append(SQLRowChange(row: row, action: removing ? "Eliminar fila" : "Actualizar fila", identity: identity,
                                     fields: fields))
        }
        for (index, values) in inserted.enumerated() {
            let fields = result.columns.indices.compactMap { column -> SQLFieldChange? in
                guard self.column(column)?.generated != true else { return nil }
                return SQLFieldChange(name: result.origins[column].column, before: nil, after: values[column])
            }
            rows.append(SQLRowChange(row: result.rows.count + index, action: "Insertar fila", identity: "Fila nueva \(index + 1)",
                                     fields: fields))
        }
        return rows
    }
}
