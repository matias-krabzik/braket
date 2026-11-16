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

    init?(_ sql: String, page: Int, noBackslashEscapes: Bool = false) {
        guard !sql.contains("/*!"), !sql.contains("/*M!") else { return nil }
        // El recorrido léxico es el de SQLScript: un segundo parser con sus propias reglas
        // sobre cadenas y comentarios se separaría del que decide qué se ejecuta.
        let outer = SQLScript.scan(sql, noBackslashEscapes: noBackslashEscapes).words.filter { $0.depth == 0 }
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
}
