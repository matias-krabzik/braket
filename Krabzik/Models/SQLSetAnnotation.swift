import Foundation

struct SQLSetValue: Sendable, Equatable {
    let name: String
    let value: String
    var isList = false
    var listSnapshot: SQLClientList?
    var detail: String?
    var reference: String?

    var clipboardReference: String? { name == "SET" && reference == nil ? nil : (reference ?? name) }
    var clipboardValues: String? {
        if isList { return listSnapshot.flatMap { $0.values.isEmpty ? nil : $0.sql } }
        return value
    }
}

struct SQLSetNote {
    let connectionID: UUID
    let values: [SQLSetValue]
    var error: String?
}

/// Only validated assignment targets are read back. Expressions are never evaluated twice.
struct SQLSetStatement {
    struct Target {
        let label: String
        let expression: String
    }

    let targets: [Target]

    init?(_ sql: String, noBackslashEscapes: Bool = false) {
        let scan = SQLScript.scan(sql, noBackslashEscapes: noBackslashEscapes, collectLexemes: true)
        guard scan.words.first?.word == "SET" else { return nil }
        guard !scan.hasExecutableComment else { targets = []
        return }
        let tokens = scan.lexemes.filter { $0.depth == 0 }
        var scope = "SESSION"
        var body = Array(tokens.dropFirst())
        if let first = body.first, Self.scopes.contains(first.text.uppercased()) {
            scope = Self.readScope(first.text)
            body.removeFirst()
        }
        if body.first?.text.uppercased() == "NAMES" || body.prefix(2).map({ $0.text.uppercased() }) == ["CHARACTER", "SET"] {
            targets = ["character_set_client", "character_set_connection", "character_set_results"].map {
                Target(label: $0, expression: "@@SESSION." + SQLValue.identifier($0))
            }
            return
        }
        targets = body.split { $0.text == "," && !$0.quoted }.compactMap { segment in
            guard let equals = segment.firstIndex(where: { $0.text == "=" && !$0.quoted }) else { return nil }
            var left = Array(segment[..<equals])
            if left.last?.text == ":" { left.removeLast() }
            var targetScope = scope
            if let first = left.first, Self.scopes.contains(first.text.uppercased()) {
                targetScope = Self.readScope(first.text)
                left.removeFirst()
            }
            if left.count == 2, left[0].text == "@", Self.isName(left[1]) {
                return Target(label: "@" + left[1].text, expression: "@" + left[1].text)
            }
            if left.first?.text == "@", left.dropFirst().first?.text == "@" {
                left.removeFirst(2)
                if left.count == 3, left[1].text == ".", Self.scopes.contains(left[0].text.uppercased()) {
                    targetScope = Self.readScope(left.removeFirst().text)
                    left.removeFirst()
                }
            }
            guard left.count == 1, Self.isName(left[0]), !left[0].quoted else { return nil }
            let name = left[0].text
            guard !["PASSWORD", "ROLE", "TRANSACTION"].contains(name.uppercased()) else { return nil }
            return Target(label: name, expression: "@@" + targetScope + "." + SQLValue.identifier(name))
        }
    }

    private static let scopes: Set<String> = ["SESSION", "LOCAL", "GLOBAL", "PERSIST", "PERSIST_ONLY"]

    private static func readScope(_ text: String) -> String {
        ["GLOBAL", "PERSIST", "PERSIST_ONLY"].contains(text.uppercased()) ? "GLOBAL" : "SESSION"
    }

    private static func isName(_ token: SQLLexeme) -> Bool {
        if token.quoted { return token.text.count >= 2 }
        return !token.text.isEmpty && token.text.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "$" }
    }

    var query: String? {
        guard !targets.isEmpty else { return nil }
        return "SELECT " + targets.map { "LEFT(CAST(" + $0.expression + " AS CHAR), 2048)" }.joined(separator: ", ")
    }
}
