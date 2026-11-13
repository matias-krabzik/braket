import Foundation
import Observation

@MainActor @Observable
final class SQLSchemaStore {
    struct Preference: Codable {
        var visible: [String] = []
        var defaultDatabase = ""
    }
    var snapshots: [UUID: SQLSchemaSnapshot] = [:]
    var preferences: [UUID: Preference] = [:]
    var loading: Set<UUID> = []
    var errors: [UUID: String] = [:]
    var choosing: DatabaseConnection?
    var available: [UUID: [String]] = [:]
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: "mysql.schemaPreferences.v1"),
           let saved = try? JSONDecoder().decode([UUID: Preference].self, from: data) { preferences = saved }
        if let data = defaults.data(forKey: "mysql.schemaCache.v1"),
           let saved = try? JSONDecoder().decode([UUID: SQLSchemaSnapshot].self, from: data) { snapshots = saved }
    }

    func snapshot(_ connection: DatabaseConnection) -> SQLSchemaSnapshot? {
        guard let cached = snapshots[connection.id], cached.connection == connection else { return nil }
        return cached
    }

    func preference(_ connection: DatabaseConnection) -> Preference {
        preferences[connection.id] ?? Preference(visible: connection.database.isEmpty ? [] : [connection.database],
                                                 defaultDatabase: connection.database)
    }

    func save(_ preference: Preference, for connection: DatabaseConnection) {
        preferences[connection.id] = preference
        if let data = try? JSONEncoder().encode(preferences) { defaults.set(data, forKey: "mysql.schemaPreferences.v1") }
    }

    func discover(_ connection: DatabaseConnection, client: MySQLClient, choose: Bool = false) async {
        guard loading.insert(connection.id).inserted else { return }
        defer { loading.remove(connection.id) }
        errors[connection.id] = nil
        do {
            let password = try CredentialStore.read(for: connection)
            available[connection.id] = try await client.databases(connection, password: password)
            if choose || preferences[connection.id] == nil { choosing = connection }
            let visible = preference(connection).visible
            if !visible.isEmpty {
                let snapshot = try await client.schema(connection, password: password, databases: visible)
                snapshots[connection.id] = snapshot
                // Limit the on-disk cache without retaining credentials or result data.
                if let data = try? JSONEncoder().encode(snapshots), data.count <= 20_000_000 {
                    defaults.set(data, forKey: "mysql.schemaCache.v1")
                }
            }
        } catch { errors[connection.id] = MySQLClient.message(error) }
    }

    func completions(connection: DatabaseConnection?, database: String, text: String, position: Int) -> [String] {
        guard let connection, let snapshot = snapshot(connection) else { return [] }
        let source = text as NSString
        let before = source.substring(to: min(position, source.length))
        let token = String(before.reversed().prefix { $0.isLetter || $0.isNumber || "_.$`".contains($0) }.reversed())
        let parts = token.replacingOccurrences(of: "`", with: "").split(separator: ".", omittingEmptySubsequences: false)
        var names: [String] = []
        if parts.count > 1 {
            let qualifier = String(parts[parts.count - 2])
            let aliases = Self.aliases(in: text)
            let tableName = aliases[qualifier.lowercased()] ?? qualifier
            names = snapshot.tables.filter { $0.name.caseInsensitiveCompare(tableName) == .orderedSame }
                .flatMap { $0.columns.map(\.name) }
            names += snapshot.tables.filter { $0.database == qualifier }.map(\.name)
        } else {
            names = snapshot.databases + snapshot.tables.map(\.name)
            names += snapshot.tables.filter { database.isEmpty || $0.database == database }.flatMap { $0.columns.map(\.name) }
        }
        let prefix = String(parts.last ?? "")
        return Array(Set(names)).filter { $0.lowercased().hasPrefix(prefix.lowercased()) }.sorted().prefix(200).map {
            $0.range(of: #"^[\p{L}_][\p{L}\p{N}_$]*$"#, options: .regularExpression) != nil ? $0 : SQLValue.identifier($0)
        }
    }

    private static func aliases(in text: String) -> [String: String] {
        let pattern = #"(?i)\b(?:FROM|JOIN)\s+(?:`?\w+`?\.)?`?(\w+)`?\s+(?:AS\s+)?`?(\w+)`?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [:] }
        let source = text as NSString
        var result: [String: String] = [:]
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            result[source.substring(with: match.range(at: 2)).lowercased()] = source.substring(with: match.range(at: 1))
        }
        return result
    }
}
