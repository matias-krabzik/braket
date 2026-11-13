import Foundation

struct SQLPage: Sendable, Equatable {
    static let size = 100
    var index = 0
    var totalRows: Int?
    var hasNext = false
    var count: Int? { totalRows.map { max(1, ($0 + Self.size - 1) / Self.size) } }
}

/// Reconoce cláusulas externas sin confundir literales, comentarios ni subconsultas.
struct SQLPagination: Sendable {
    let query: String
    let countQuery: String?
    let index: Int

    private struct Token {
        let word: String
        let offset: Int
        let depth: Int
    }

    init?(_ sql: String, page: Int, noBackslashEscapes: Bool = false) {
        guard !sql.contains("/*!"), !sql.contains("/*M!") else { return nil }
        let tokens = Self.tokens(sql, noBackslashEscapes: noBackslashEscapes)
        let outer = tokens.filter { $0.depth == 0 }
        guard let first = outer.first, first.word == "SELECT" || first.word == "WITH",
              outer.contains(where: { $0.word == "SELECT" }),
              !outer.contains(where: { ["LIMIT", "INTO"].contains($0.word) }) else { return nil }
        let lock = outer.first { $0.word == "FOR" || $0.word == "LOCK" }
        let bytes = Array(sql.utf8)
        let split = lock?.offset ?? bytes.count
        let prefix = String(decoding: bytes[..<split], as: UTF8.self)
        let suffix = String(decoding: bytes[split...], as: UTF8.self)
        index = max(0, min(page, 10_000_000))
        // Una fila adicional permite avanzar aunque el servidor no pueda calcular el total.
        query = prefix + "\nLIMIT \(SQLPage.size + 1) OFFSET \(index * SQLPage.size)\n" + suffix
        countQuery = lock == nil ? "SELECT COUNT(*) FROM (\n" + sql + "\n) AS `_braket_page_count`" : nil
    }

    private static func tokens(_ sql: String, noBackslashEscapes: Bool) -> [Token] {
        let bytes = Array(sql.utf8)
        var index = 0, depth = 0
        var output: [Token] = []
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 39 || byte == 34 || byte == 96 {
                let quote = byte
                index += 1
                while index < bytes.count {
                    if bytes[index] == 92 && !noBackslashEscapes { index = min(index + 2, bytes.count) }
                    else if bytes[index] == quote {
                        index += 1
                        if index < bytes.count, bytes[index] == quote { index += 1 } else { break }
                    } else { index += 1 }
                }
            } else if byte == 35 || (byte == 45 && index + 2 < bytes.count && bytes[index + 1] == 45 && bytes[index + 2] <= 32) {
                while index < bytes.count, bytes[index] != 10 { index += 1 }
            } else if byte == 47 && index + 1 < bytes.count && bytes[index + 1] == 42 {
                index += 2
                while index + 1 < bytes.count, !(bytes[index] == 42 && bytes[index + 1] == 47) { index += 1 }
                index = min(index + 2, bytes.count)
            } else if byte == 40 { depth += 1
            index += 1 }
            else if byte == 41 { depth -= 1
            index += 1 }
            else if (65...90).contains(byte) || (97...122).contains(byte) || byte == 95 {
                let start = index
                while index < bytes.count,
                      (65...90).contains(bytes[index]) || (97...122).contains(bytes[index])
                        || (48...57).contains(bytes[index]) || bytes[index] == 95 { index += 1 }
                output.append(Token(word: String(decoding: bytes[start..<index], as: UTF8.self).uppercased(), offset: start, depth: depth))
            } else { index += 1 }
        }
        return output
    }
}
