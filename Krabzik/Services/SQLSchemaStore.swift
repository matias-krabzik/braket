import Foundation
import Observation

protocol SQLSchemaSource: Sendable {
    func databases(_ config: DatabaseConnection, password: String) async throws -> [String]
    func schema(_ config: DatabaseConnection, password: String, databases: [String],
                progress: @escaping @Sendable (SQLSchemaProgress) async -> Void) async throws -> SQLSchemaSnapshot
}

extension MySQLClient: SQLSchemaSource {}

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
    var progress: [UUID: String] = [:]
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var generations: [UUID: UUID] = [:]
    @ObservationIgnored private let readPassword: @Sendable (DatabaseConnection) throws -> String
    var choosing: DatabaseConnection?
    var selectionHosts: [UUID] = []
    var available: [UUID: [String]] = [:]
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard,
         readPassword: @escaping @Sendable (DatabaseConnection) throws -> String = { try CredentialStore.read(for: $0) }) {
        self.defaults = defaults
        self.readPassword = readPassword
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

    func cancel(_ id: UUID) {
        tasks.removeValue(forKey: id)?.cancel()
        generations.removeValue(forKey: id)
        loading.remove(id)
        progress.removeValue(forKey: id)
        errors[id] = "Carga de estructura cancelada. Podés reintentar."
    }

    func cancelAll() {
        for id in Array(tasks.keys) { cancel(id) }
    }

    func discover(_ connection: DatabaseConnection, client: any SQLSchemaSource, choose: Bool = false) async {
        if loading.contains(connection.id) {
            guard choose else { return }
            cancel(connection.id)
        }
        let token = UUID()
        generations[connection.id] = token
        loading.insert(connection.id)
        errors[connection.id] = nil
        progress[connection.id] = "Conectando para leer la estructura…"
        let task = Task { await self.load(connection, client: client, choose: choose, token: token) }
        tasks[connection.id] = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    private func load(_ connection: DatabaseConnection, client: any SQLSchemaSource, choose: Bool, token: UUID) async {
        let id = connection.id
        defer {
            if generations[id] == token {
                loading.remove(id)
                progress.removeValue(forKey: id)
                tasks.removeValue(forKey: id)
                generations.removeValue(forKey: id)
            }
        }
        do {
            if !choose, preferences[id] != nil, preference(connection).visible.isEmpty {
                snapshots[id] = SQLSchemaSnapshot(connection: connection, databases: [], tables: [], isPartial: false)
                return
            }
            let password = try readPassword(connection)
            // Choosing databases must never wait for introspection of the previous selection.
            if choose || preferences[id] == nil {
                progress[id] = "Buscando bases disponibles…"
                let names = try await client.databases(connection, password: password)
                try Task.checkCancellation()
                guard generations[id] == token else { return }
                available[id] = names
                choosing = connection
                return
            }
            let visible = preference(connection).visible
            var initial = snapshot(connection) ?? SQLSchemaSnapshot(connection: connection, databases: visible, tables: [])
            initial.databases = visible
            initial.tables.removeAll { !visible.contains($0.database) }
            initial.isPartial = !visible.isEmpty
            snapshots[id] = initial
            let snapshot = try await client.schema(connection, password: password, databases: visible) { update in
                await MainActor.run {
                    guard self.generations[id] == token else { return }
                    self.progress[id] = update.message
                    if let tables = update.tables {
                        self.snapshots[id]?.tables.removeAll { $0.database == update.database }
                        self.snapshots[id]?.tables.append(contentsOf: tables)
                    }
                }
            }
            try Task.checkCancellation()
            guard generations[id] == token else { return }
            snapshots[id] = snapshot
            if let data = try? JSONEncoder().encode(snapshots), data.count <= 20_000_000 {
                defaults.set(data, forKey: "mysql.schemaCache.v1")
            }
        } catch {
            guard generations[id] == token else { return }
            errors[id] = Task.isCancelled ? "Carga de estructura cancelada. Podés reintentar."
                : (progress[id].map { $0 + "\n" } ?? "") + MySQLClient.message(error)
        }
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
