import Foundation
import Observation

/// Catálogo global de perfiles. Las contraseñas permanecen en el llavero.
@MainActor @Observable
final class ConnectionStore {
    static let profilesKey = "mysql.globalConnections.v1"
    static let selectionsKey = "mysql.scriptConnections.v1"
    private let session: WorkspaceSession
    private let database: DatabaseController
    private let defaults: UserDefaults
    private(set) var profiles: [DatabaseConnection]
    private var selections: [String: String]
    private var migrated: Set<String>

    init(session: WorkspaceSession, database: DatabaseController, defaults: UserDefaults = .standard) {
        self.session = session
        self.database = database
        self.defaults = defaults
        profiles = defaults.data(forKey: Self.profilesKey)
            .flatMap { try? JSONDecoder().decode([DatabaseConnection].self, from: $0) } ?? []
        selections = defaults.dictionary(forKey: Self.selectionsKey) as? [String: String] ?? [:]
        migrated = Set(defaults.stringArray(forKey: "mysql.migratedProfiles.v1") ?? [])
        for connection in profiles { _ = database.state(connection.id) }
    }

    /// Cada archivo conserva una selección independiente, compartida entre proyectos.
    func selected(for document: EditorDocument) -> DatabaseConnection? {
        guard let id = selections[document.url.standardizedFileURL.path] else { return nil }
        return profiles.first { $0.id.uuidString == id }
    }

    func select(_ id: UUID?, for document: EditorDocument) {
        guard !document.sqlExecution.isRunning,
              id == nil || profiles.contains(where: { $0.id == id }) else { return }
        selections[document.url.standardizedFileURL.path] = id?.uuidString
        defaults.set(selections, forKey: Self.selectionsKey)
    }

    /// Importa una sola vez los perfiles de proyectos confiables, sin sobrescribir el catálogo.
    func install(_ connections: [DatabaseConnection]) {
        database.editingConnection = nil
        guard !session.isReadOnly, let url = session.url else { return }
        for original in connections {
            let key = url.standardizedFileURL.path + "|" + original.id.uuidString
            guard !migrated.contains(key) else { continue }
            do {
                var connection = try original.validated()
                if let existing = profiles.first(where: { $0.id == original.id }), existing != original {
                    connection.id = UUID()
                    let password = try CredentialStore.read(for: original)
                    if !password.isEmpty { try CredentialStore.save(password, for: connection) }
                }
                if !profiles.contains(where: { $0.id == connection.id }) {
                    var updated = profiles
                    updated.append(connection)
                    try persist(updated)
                    _ = database.state(connection.id)
                }
                migrated.insert(key)
                defaults.set(Array(migrated), forKey: "mysql.migratedProfiles.v1")
            } catch { session.errors.report(error) }
        }
    }

    static func endpointChanged(from previous: DatabaseConnection, to connection: DatabaseConnection) -> Bool {
        previous.host.lowercased() != connection.host.lowercased()
            || previous.port != connection.port
            || previous.username != connection.username
            || previous.tls != connection.tls
    }

    func save(_ connection: DatabaseConnection, password: String) async throws {
        let connection = try connection.validated()
        let previous = profiles.first { $0.id == connection.id }
        if let previous {
            guard await database.disconnect(previous) else {
                throw DatabaseFailure("La conexión está ocupada o se canceló el cambio.")
            }
        }
        let oldPassword = try CredentialStore.read(for: connection)
        var updated = profiles
        if let index = updated.firstIndex(where: { $0.id == connection.id }) { updated[index] = connection }
        else { updated.append(connection) }
        try CredentialStore.save(password, for: connection)
        do { try persist(updated) }
        catch {
            try? CredentialStore.save(oldPassword, for: connection)
            throw error
        }
        if let previous, Self.endpointChanged(from: previous, to: connection) { forget(previous) }
        database.states[connection.id] = DatabaseState()
    }

    func remove(_ connection: DatabaseConnection) {
        Task {
            guard await database.disconnect(connection) else { return }
            do { try persist(profiles.filter { $0.id != connection.id }) }
            catch { session.errors.report(error)
                return }
            forget(connection)
            database.states.removeValue(forKey: connection.id)
            selections = selections.filter { $0.value != connection.id.uuidString }
            defaults.set(selections, forKey: Self.selectionsKey)
        }
    }

    private func persist(_ updated: [DatabaseConnection]) throws {
        let data = try JSONEncoder().encode(updated)
        defaults.set(data, forKey: Self.profilesKey)
        profiles = updated
    }

    private func forget(_ connection: DatabaseConnection) {
        do { try CredentialStore.remove(for: connection) }
        catch { session.errors.report(error) }
    }
}
