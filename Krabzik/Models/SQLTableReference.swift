import Foundation

/// Referencias reales a tablas, con posiciones del lexer MySQL compartido.
/// No interpreta alias, columnas, comentarios ni literales como destinos de navegación.
struct SQLTableReference: Equatable {
    let database: String?
    let name: String

    static func at(_ position: Int, in sql: String, noBackslashEscapes: Bool = false) -> SQLTableReference? {
        guard position >= 0, position < sql.utf16.count else { return nil }
        let tokens = SQLScript.scan(sql, noBackslashEscapes: noBackslashEscapes, collectLexemes: true).lexemes
        let utf16 = sql as NSString
        let bytePosition = utf16.substring(to: position).utf8.count
        guard let clicked = tokens.firstIndex(where: {
            bytePosition >= $0.offset && bytePosition < $0.offset + $0.text.utf8.count
        }) else { return nil }
        var start = clicked
        if clicked >= 2, tokens[clicked - 1].text == "." { start -= 2 }
        guard let first = identifier(tokens[start]) else { return nil }
        var end = start, database: String?, name = first
        if start + 2 < tokens.count, tokens[start + 1].text == ".",
           let qualified = identifier(tokens[start + 2]) {
            database = first
            name = qualified
            end = start + 2
        }
        guard clicked == start || clicked == end, start > 0,
              tokens[start - 1].depth == tokens[start].depth else { return nil }
        let previous = tokens[start - 1]
        let introducers: Set<String> = ["FROM", "JOIN", "STRAIGHT_JOIN", "UPDATE", "INTO", "TABLE", "REFERENCES"]
        var isSource = !previous.quoted && introducers.contains(previous.text.uppercased())
        if previous.text == "," {
            let boundaries: Set<String> = ["FROM", "JOIN", "WHERE", "ON", "SET", "SELECT", "ORDER", "GROUP", "LIMIT", ";"]
            let clause = tokens[..<(start - 1)].last {
                $0.depth == previous.depth && !$0.quoted && boundaries.contains($0.text.uppercased())
            }
            isSource = clause?.text.uppercased() == "FROM"
        }
        guard isSource else { return nil }
        // Una CTE es un resultado local, no una tabla física con CREATE TABLE.
        if database == nil {
            let boundary = tokens[..<start].lastIndex { $0.text == ";" }.map { $0 + 1 } ?? 0
            for index in boundary..<start where index + 2 < tokens.count {
                if !tokens[index + 1].quoted, tokens[index + 1].text.uppercased() == "AS",
                   tokens[index + 2].depth > tokens[index].depth,
                   identifier(tokens[index])?.caseInsensitiveCompare(name) == .orderedSame { return nil }
            }
        }
        // Conservar el nombre exacto (incluidos backticks escapados), sin normalizar su capitalización.
        return SQLTableReference(database: database, name: name)
    }

    private static func identifier(_ token: SQLLexeme) -> String? {
        if token.quoted {
            guard token.text.hasPrefix("`"), token.text.hasSuffix("`"), token.text.count > 2 else { return nil }
            return String(token.text.dropFirst().dropLast()).replacingOccurrences(of: "``", with: "`")
        }
        let keywords: Set<String> = ["SELECT", "WHERE", "SET", "VALUES", "AS", "JOIN", "ON", "ORDER", "GROUP", "LIMIT"]
        guard !keywords.contains(token.text.uppercased()),
              token.text.range(of: #"^[A-Za-z_][A-Za-z0-9_$]*$"#, options: .regularExpression) != nil else { return nil }
        return token.text
    }
}
