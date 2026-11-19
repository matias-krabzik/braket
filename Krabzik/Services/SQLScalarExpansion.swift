import Foundation

/// Reads current session values, never the truncated display annotations or cached SET expressions.
struct SQLScalarExpansion {
    let sql: String
    let references: [NSTextCheckingResult]
    let names: [String]

    init(_ sql: String, noBackslashEscapes: Bool = false) throws {
        self.sql = sql
        let scan = SQLScript.scan(sql, noBackslashEscapes: noBackslashEscapes)
        let code = SQLListStatement.code(sql, noBackslashEscapes: noBackslashEscapes)
        // Leave statements that assign variables under MySQL's evaluation rules.
        guard !scan.hasExecutableComment,
              ["SELECT", "WITH", "INSERT", "UPDATE", "DELETE", "REPLACE"].contains(scan.outer.first ?? ""),
              !scan.outer.contains("INTO"),
              code.range(of: #":\s*="#, options: .regularExpression) == nil else {
            references = []
            names = []
            return
        }
        let regex = try NSRegularExpression(pattern: #"(?<![@\w$])@[A-Za-z0-9_$]+(?:\.[A-Za-z0-9_$]+)*(?![\w$])"#)
        references = regex.matches(in: code, range: NSRange(location: 0, length: (code as NSString).length))
        var unique: [String] = []
        for match in references {
            let name = (sql as NSString).substring(with: match.range)
            if !unique.contains(name) { unique.append(name) }
        }
        names = unique
    }

    var query: String? { names.isEmpty ? nil : "SELECT " + names.joined(separator: ", ") }

    func expand(_ result: SQLResult) throws -> String {
        guard !result.truncated, result.rows.count == 1, let row = result.rows.first,
              row.count == names.count, result.origins.count == names.count else {
            throw DatabaseFailure("No se pudieron leer completos los valores de las variables.")
        }
        var literals: [String: String] = [:]
        for (index, name) in names.enumerated() {
            guard let value = row[index] else { literals[name] = "NULL"
            continue }
            let origin = result.origins[index]
            guard !origin.binary else { throw DatabaseFailure("La variable \(name) contiene datos binarios.") }
            if [0, 1, 2, 3, 4, 5, 8, 9, 13, 246].contains(Int(origin.mysqlType ?? 253)) {
                guard value.range(of: #"^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$"#,
                                  options: .regularExpression) != nil else {
                    throw DatabaseFailure("Valor numérico no válido en \(name).")
                }
                literals[name] = value
            } else { literals[name] = SQLValue.literal(value) }
        }
        let expanded = NSMutableString(string: sql)
        for match in references.reversed() {
            let name = (sql as NSString).substring(with: match.range)
            guard let literal = literals[name] else { throw DatabaseFailure("No se pudo resolver \(name).") }
            expanded.replaceCharacters(in: match.range, with: literal)
            guard expanded.length <= 1_000_000 else { throw DatabaseFailure("La consulta expandida supera 1 MB.") }
        }
        guard (expanded as String).utf8.count <= 1_000_000 else { throw DatabaseFailure("La consulta expandida supera 1 MB.") }
        return expanded as String
    }
}
