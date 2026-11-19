import Foundation

struct SQLListStatement {
    let name: String
    let query: String

    static func code(_ sql: String, noBackslashEscapes: Bool) -> String {
        let masked = NSMutableString(string: sql)
        for span in SQLScript.scan(sql, noBackslashEscapes: noBackslashEscapes, collectSyntax: true).syntax.reversed()
            where ["string", "comment", "type"].contains(span.token) {
            masked.replaceCharacters(in: span.range, with: String(repeating: " ", count: span.range.length))
        }
        return masked as String
    }

    static func parse(_ sql: String, noBackslashEscapes: Bool = false) throws -> Self? {
        let scan = SQLScript.scan(sql, noBackslashEscapes: noBackslashEscapes)
        guard Array(scan.outer.prefix(2)) == ["SET", "LIST"] else { return nil }
        let masked = code(sql, noBackslashEscapes: noBackslashEscapes) as NSString
        let regex = try NSRegularExpression(pattern: #"(?i)^\s*SET\s+LIST\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*\("#)
        guard !scan.hasExecutableComment, let match = regex.firstMatch(in: masked as String,
                                                                       range: NSRange(location: 0, length: masked.length)) else {
            throw DatabaseFailure("Usá SET LIST nombre = (SELECT una_columna FROM tabla).")
        }
        let start = NSMaxRange(match.range)
        var depth = 1, end = start
        while end < masked.length, depth > 0 {
            if masked.character(at: end) == 40 { depth += 1 }
            if masked.character(at: end) == 41 { depth -= 1 }
            if depth > 0 { end += 1 }
        }
        guard depth == 0, masked.substring(from: end + 1).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DatabaseFailure("SET LIST necesita un SELECT entre paréntesis, sin texto después del cierre.")
        }
        let query = (sql as NSString).substring(with: NSRange(location: start, length: end - start))
        var cursor = SQLScript(query)
        guard let single = try cursor.next(noBackslashEscapes: noBackslashEscapes),
              try cursor.next(noBackslashEscapes: noBackslashEscapes) == nil,
              ["SELECT", "WITH"].contains(SQLScript.scan(single.text, noBackslashEscapes: noBackslashEscapes).outer.first ?? ""),
              SQLWriteGuard.effect(of: single.text, noBackslashEscapes: noBackslashEscapes) == .read else {
            throw DatabaseFailure("SET LIST solo admite un SELECT de lectura y sin bloqueos.")
        }
        return Self(name: masked.substring(with: match.range(at: 1)), query: single.text)
    }

    static func expand(_ sql: String, lists: [String: SQLClientList], noBackslashEscapes: Bool = false) throws -> String {
        let masked = code(sql, noBackslashEscapes: noBackslashEscapes) as NSString
        let regex = try NSRegularExpression(pattern: #"\{\{([^{}]*)\}\}"#)
        let matches = regex.matches(in: masked as String, range: NSRange(location: 0, length: masked.length))
        let result = NSMutableString(string: sql)
        for match in matches.reversed() {
            let name = masked.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let list = lists[name]
                else { throw DatabaseFailure("La lista {{\(name)}} no existe en este proyecto. Ejecutá su SET LIST.") }
            guard !list.values.isEmpty else { throw DatabaseFailure("La lista {{\(name)}} está vacía. No se ejecutó la consulta.") }
            let prefix = masked.substring(to: match.range.location)
            let suffix = masked.substring(from: NSMaxRange(match.range))
            guard prefix.range(of: #"(?i)\bIN\s*\(\s*$"#, options: .regularExpression) != nil,
                  suffix.range(of: #"^\s*\)"#, options: .regularExpression) != nil else {
                throw DatabaseFailure("Usá {{\(name)}} como lista completa: IN ({{\(name)}}).")
            }
            result.replaceCharacters(in: match.range, with: list.sql)
            guard result.length <= 1_000_000 else { throw DatabaseFailure("La consulta expandida supera 1 MB.") }
        }
        let remaining = regex.stringByReplacingMatches(in: masked as String, range: NSRange(location: 0, length: masked.length),
                                                       withTemplate: "")
        guard !remaining.contains("{{"),
              !remaining.contains("}}") else { throw DatabaseFailure("Referencia de lista incompleta: {{nombre}}.") }
        guard (result as String).utf8.count <= 1_000_000 else { throw DatabaseFailure("La consulta expandida supera 1 MB.") }
        return result as String
    }
}
