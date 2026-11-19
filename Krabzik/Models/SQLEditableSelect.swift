import Foundation

/// Prueba conservadora de una sola tabla exterior. Las subconsultas del WHERE solo
/// filtran filas; nunca se usan sus tablas ni sus claves para generar escrituras.
enum SQLEditableSelect {
    static func matches(_ sql: String, table: SQLSchemaTable, noBackslashEscapes: Bool = false) -> Bool {
        var cursor = SQLScript(sql)
        let statement: SQLStatement
        do {
            guard let first = try cursor.next(noBackslashEscapes: noBackslashEscapes),
                  try cursor.next(noBackslashEscapes: noBackslashEscapes) == nil else { return false }
            statement = first
        } catch { return false }
        let scan = SQLScript.scan(statement.text, noBackslashEscapes: noBackslashEscapes, collectLexemes: true)
        let outer = scan.words.filter { $0.depth == 0 }
        let forbidden: Set<String> = ["JOIN", "STRAIGHT_JOIN", "UNION", "INTERSECT", "EXCEPT", "GROUP",
                                      "DISTINCT", "DISTINCTROW", "HAVING", "PROCEDURE", "INTO", "WINDOW", "QUALIFY"]
        guard !scan.hasExecutableComment, outer.first?.word == "SELECT",
              outer.filter({ $0.word == "SELECT" }).count == 1,
              !outer.contains(where: { forbidden.contains($0.word) }),
              let from = outer.first(where: { $0.word == "FROM" }),
              outer.filter({ $0.word == "FROM" }).count == 1 else { return false }
        let whereStart = outer.first { $0.word == "WHERE" && $0.offset > from.offset }?.offset
        let whereEnd = outer.first { word in
            word.offset > (whereStart ?? Int.max) && ["ORDER", "LIMIT", "FOR", "LOCK"].contains(word.word)
        }?.offset ?? statement.text.utf8.count
        for word in scan.words where word.word == "SELECT" && word.depth > 0 {
            guard let whereStart, word.offset > whereStart, word.offset < whereEnd else { return false }
        }
        // Reusar el lexer, incluyendo sus reglas de comentarios, cadenas y backticks.
        let code = SQLListStatement.code(statement.text, noBackslashEscapes: noBackslashEscapes)
        var depth = 0
        for character in code {
            if character == "(" { depth += 1 }
            if character == ")" { depth -= 1 }
            if depth < 0 { return false }
        }
        guard depth == 0 else { return false }
        let tokens = scan.lexemes
        guard let start = tokens.firstIndex(where: { !$0.quoted && $0.depth == 0 && $0.text.uppercased() == "FROM" }) else {
            return false
        }
        let rest = tokens.dropFirst(start + 1)
        let end = rest.firstIndex {
            $0.depth == 0 && !$0.quoted && ["WHERE", "ORDER", "LIMIT", "FOR", "LOCK", ";"].contains($0.text.uppercased())
        } ?? tokens.endIndex
        let source = Array(tokens[(start + 1)..<end])
        guard source.allSatisfy({ $0.depth == 0 }), let first = source.first,
              let firstName = identifier(first) else { return false }
        var index = 1, database: String?, name = firstName
        if source.count > 1, source[1].text == "." {
            guard source.count > 2, let qualified = identifier(source[2]) else { return false }
            database = firstName
            name = qualified
            index = 3
        }
        if index < source.count {
            if !source[index].quoted && source[index].text.uppercased() == "AS" { index += 1 }
            guard index < source.count, identifier(source[index]) != nil else { return false }
            index += 1
        }
        return index == source.count && name.caseInsensitiveCompare(table.name) == .orderedSame
            && (database == nil || database?.caseInsensitiveCompare(table.database) == .orderedSame)
    }

    private static func identifier(_ token: SQLLexeme) -> String? {
        if token.quoted {
            guard token.text.hasPrefix("`"), token.text.hasSuffix("`"), token.text.count > 2 else { return nil }
            return String(token.text.dropFirst().dropLast()).replacingOccurrences(of: "``", with: "`")
        }
        return token.text.range(of: #"^[\p{L}_][\p{L}\p{N}_$]*$"#, options: .regularExpression) == nil ? nil : token.text
    }
}
