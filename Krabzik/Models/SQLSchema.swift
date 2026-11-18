import Foundation

struct SQLColumnOrigin: Sendable, Equatable {
    var database: String
    var table: String
    var column: String
    var binary = false
}

struct SQLSchemaColumn: Codable, Sendable, Equatable, Identifiable {
    var name: String
    var type: String
    var nullable: Bool
    var defaultValue: String?
    var extra: String
    var id: String { name }
    var generated: Bool { extra.uppercased().contains("GENERATED") && !extra.uppercased().contains("DEFAULT_GENERATED") }
    var autoIncrement: Bool { extra.lowercased().contains("auto_increment") }
    var canDefault: Bool { nullable || defaultValue != nil || autoIncrement || generated }
    var enumValues: [String] {
        guard type.lowercased().hasPrefix("enum("), type.hasSuffix(")") else { return [] }
        let chars = Array(type.dropFirst(5).dropLast())
        var values: [String] = [], value = "", quoted = false, index = 0
        while index < chars.count {
            let char = chars[index]
            if quoted, char == "\\", index + 1 < chars.count {
                index += 1
                let escaped = chars[index]
                value.append(["n": "\n", "r": "\r", "t": "\t", "0": "\0" ][escaped] ?? escaped)
            } else if char == "'" {
                if quoted, index + 1 < chars.count, chars[index + 1] == "'" { value.append("'")
                index += 1 }
                else if quoted { values.append(value)
                value = ""
                quoted = false }
                else { quoted = true }
            } else if quoted { value.append(char) }
            index += 1
        }
        return values
    }
}

struct SQLSchemaTable: Codable, Sendable, Equatable, Identifiable {
    var database: String
    var name: String
    var kind: String
    var engine: String
    var columns: [SQLSchemaColumn] = []
    var uniqueKeys: [[String]] = []
    var primaryKey: [String]?
    var createSQL: String?
    var metadataComplete: Bool?
    var id: String { database + "." + name }
    var qualified: String { SQLValue.identifier(database) + "." + SQLValue.identifier(name) }

    /// La PK tiene prioridad. Si existe, no se sustituye por otra clave que sí esté en la proyección.
    func editingKey(in names: Set<String>) -> [String]? {
        let candidates = primaryKey.flatMap { $0.isEmpty ? nil : [$0] } ?? uniqueKeys
        return candidates.first { key in
            !key.isEmpty && key.allSatisfy { name in
                names.contains(name) && columns.contains { $0.name == name && !$0.nullable }
            }
        }
    }
}

struct SQLSchemaSnapshot: Codable, Sendable {
    var connection: DatabaseConnection
    var databases: [String]
    var tables: [SQLSchemaTable]
    var fetchedAt = Date()
    var isPartial: Bool?
}

enum SQLValue {
    static func identifier(_ text: String) -> String { "`" + text.replacingOccurrences(of: "`", with: "``") + "`" }
    static func keyLiteral(_ text: String, column: SQLSchemaColumn?) -> String {
        let type = column?.type.lowercased().split(whereSeparator: { $0 == "(" || $0 == " " }).first.map(String.init) ?? ""
        if ["tinyint", "smallint", "mediumint", "int", "integer", "bigint"].contains(type),
           text.range(of: #"^-?[0-9]+$"#, options: .regularExpression) != nil { return text }
        return literal(text)
    }

    static func literal(_ text: String?) -> String {
        guard let text else { return "NULL" }
        return "CONVERT(X'" + text.utf8.map { String(format: "%02X", $0) }.joined() + "' USING utf8mb4)"
    }
}
