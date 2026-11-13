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
        var values: [String] = [], value = "", quoted = false, escaped = false
        for character in type.dropFirst(5).dropLast() {
            if escaped { value.append(character)
            escaped = false }
            else if character == "\\" && quoted { escaped = true }
            else if character == "'" {
                if quoted { values.append(value)
                value = "" }
                quoted.toggle()
            } else if quoted { value.append(character) }
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
    var createSQL: String?
    var metadataComplete: Bool?
    var id: String { database + "." + name }
    var qualified: String { SQLValue.identifier(database) + "." + SQLValue.identifier(name) }
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
    static func literal(_ text: String?) -> String {
        guard let text else { return "NULL" }
        return "CONVERT(X'" + text.utf8.map { String(format: "%02X", $0) }.joined() + "' USING utf8mb4)"
    }
}
