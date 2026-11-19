import Foundation

/// Captura en memoria; no pertenece a una sesión del servidor ni se serializa al proyecto.
struct SQLClientList: Sendable, Equatable {
    enum Element: Sendable, Equatable {
        case number(String), text(String)
        var sql: String {
            switch self { case .number(let value): value
            case .text(let value): SQLValue.literal(value) }
        }
    }
    let name: String
    let values: [Element]
    let query: String
    let connectionName: String
    let capturedAt = Date()
    var sql: String { values.map(\.sql).joined(separator: ", ") }
    var note: SQLSetValue {
        SQLSetValue(name: "{{" + name + "}}", value: "\(values.count) valores", isList: true, listSnapshot: self,
                    detail: "Lista de Braket · \(connectionName)\n\(capturedAt.formatted())\n"
                        + values.prefix(10).map(\.sql).joined(separator: ", ") + (values.count > 10 ? ", …" : "") + "\n" + query)
    }

    init(name: String, results: [SQLResult], query: String, connectionName: String) throws {
        guard results.count == 1, let result = results.first, result.columns.count == 1 else {
            throw DatabaseFailure("SET LIST necesita un SELECT que devuelva exactamente una columna.")
        }
        guard !result.truncated, result.rows.count == result.rowCount, result.rows.count <= 10_000 else {
            throw DatabaseFailure("La lista está incompleta o supera 10.000 filas. Acotá el SELECT; no se guardó una lista parcial.")
        }
        guard result.origins.first?.binary != true else { throw DatabaseFailure("SET LIST admite números y texto, no datos binarios.") }
        let numeric = [0, 1, 2, 3, 4, 5, 8, 9, 13, 246].contains(Int(result.origins.first?.mysqlType ?? 253))
        var values: [Element] = [], seen: Set<Data> = []
        for row in result.rows {
            guard row.count == 1 else { throw DatabaseFailure("La lista contiene una fila no válida.") }
            guard let value = row[0], seen.insert(Data(value.utf8)).inserted else { continue }
            if numeric {
                guard value.range(of: #"^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$"#,
                                  options: .regularExpression) != nil
                                  else { throw DatabaseFailure("Valor numérico no válido en la lista.") }
                values.append(.number(value))
            } else { values.append(.text(value)) }
        }
        self.name = name
        self.values = values
        self.query = query
        self.connectionName = connectionName
        guard sql.utf8.count <= 1_000_000 else { throw DatabaseFailure("La lista supera el límite de 1 MB.") }
    }
}

actor SQLClientListStore {
    private var scopes: [String: [String: SQLClientList]] = [:]
    func snapshot(_ scope: String) -> [String: SQLClientList] { scopes[scope] ?? [:] }
    func remove(_ name: String, scope: String) { scopes[scope]?.removeValue(forKey: name) }
    func set(_ list: SQLClientList, scope: String) throws {
        let existing = scopes.values.flatMap { $0.values }
        let replacing = scopes[scope]?[list.name]?.sql.utf8.count ?? 0
        guard existing.count < 100 || scopes[scope]?[list.name] != nil,
              existing.reduce(0, { $0 + $1.sql.utf8.count }) - replacing + list.sql.utf8.count <= 8_000_000 else {
            throw DatabaseFailure("Se alcanzó el límite de listas en memoria (100 listas u 8 MB).")
        }
        scopes[scope, default: [:]][list.name] = list
    }
}
