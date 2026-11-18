import Foundation
import Observation

/// Catálogo global de perfiles. Las contraseñas permanecen en el llavero.
@MainActor @Observable
final class ConnectionStore {
    static let profilesKey = "mysql.globalConnections.v1"
    static let selectionsKey = "mysql.scriptConnections.v1"
    static let recentKey = "mysql.recentConnections.v1"
    private let session: WorkspaceSession
    private let database: DatabaseController
    private let defaults: UserDefaults
    private(set) var profiles: [DatabaseConnection]
    private var selections: [String: String]
    private(set) var recentIDs: [UUID]
    private var migrated: Set<String>

    init(session: WorkspaceSession, database: DatabaseController, defaults: UserDefaults = .standard) {
        self.session = session
        self.database = database
        self.defaults = defaults
        profiles = defaults.data(forKey: Self.profilesKey)
            .flatMap { try? JSONDecoder().decode([DatabaseConnection].self, from: $0) } ?? []
        selections = defaults.dictionary(forKey: Self.selectionsKey) as? [String: String] ?? [:]
        recentIDs = (defaults.stringArray(forKey: Self.recentKey) ?? []).compactMap(UUID.init(uuidString:))
        migrated = Set(defaults.stringArray(forKey: "mysql.migratedProfiles.v1") ?? [])
        for connection in profiles { _ = database.state(connection.id) }
    }

    /// Cada archivo conserva una selección independiente, compartida entre proyectos.
    func relocateScript(from source: URL, to destination: URL) {
        let old = source.standardizedFileURL.path
        let new = destination.standardizedFileURL.path
        if let selection = selections.removeValue(forKey: old) { selections[new] = selection }
        defaults.set(selections, forKey: Self.selectionsKey)
    }

    func persistDraftSelection(_ document: EditorDocument) {
        guard !document.isDraft, let id = document.draftConnectionID else { return }
        selections[document.url.standardizedFileURL.path] = id.uuidString
        document.draftConnectionID = nil
        defaults.set(selections, forKey: Self.selectionsKey)
    }

    func selected(for document: EditorDocument) -> DatabaseConnection? {
        guard let id = document.draftConnectionID?.uuidString ?? selections[document.url.standardizedFileURL.path] else { return nil }
        return profiles.first { $0.id.uuidString == id }
    }

    var recentProfiles: [DatabaseConnection] {
        recentIDs.prefix(3).compactMap { id in profiles.first { $0.id == id } }
    }

    func select(_ id: UUID?, for document: EditorDocument) {
        let name = id.flatMap { chosen in profiles.first { $0.id == chosen }?.name } ?? ""
        QAProbe.action("connection.select", ["file": QAField.path(document.url), "connection": name,
                                             "draft": QAField.bool(document.isDraft),
                                             "running": QAField.bool(document.sqlExecution.isRunning)])
        guard !document.sqlExecution.isRunning,
              id == nil || profiles.contains(where: { $0.id == id }) else { return }
        if let previous = selected(for: document), previous.id != id {
            document.clearVariableNotes(connectionID: previous.id)
        }
        if let id {
            recentIDs.removeAll { $0 == id }
            recentIDs.insert(id, at: 0)
            recentIDs = Array(recentIDs.prefix(3))
            defaults.set(recentIDs.map(\.uuidString), forKey: Self.recentKey)
        }
        if document.isDraft { document.draftConnectionID = id
            return }
        document.draftConnectionID = nil
        selections[document.url.standardizedFileURL.path] = id?.uuidString
        defaults.set(selections, forKey: Self.selectionsKey)
    }

    /// Importa una sola vez los perfiles de proyectos confiables, sin sobrescribir el catálogo.
    func install(_ connections: [DatabaseConnection]) {
        database.editingConnection = nil
        guard !session.isReadOnly, let url = session.url else {
            QAProbe.state("state.connections", ["profiles": QAField.count(profiles.count),
                                                "imported": QAField.count(0),
                                                "readOnly": QAField.bool(session.isReadOnly)])
            return
        }
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
        QAProbe.state("state.connections", ["profiles": QAField.count(profiles.count),
                                            "imported": QAField.count(connections.count),
                                            "readOnly": QAField.bool(session.isReadOnly)])
    }

    /// Qué cuenta como «otro extremo» y obliga a soltar la credencial anterior. Incluye
    /// los parámetros avanzados de TLS: deciden contra qué identidad se verifica el
    /// servidor, así que cambiarlos cambia en quién se confía. Tiene que seguir a
    /// `CredentialStore.account(for:)`, que es la que decide dónde queda guardada.
    static func endpointChanged(from previous: DatabaseConnection, to connection: DatabaseConnection) -> Bool {
        previous.host.lowercased() != connection.host.lowercased()
            || previous.port != connection.port
            || previous.username != connection.username
            || previous.tls != connection.tls
            || previous.tlsCAPath != connection.tlsCAPath
            || previous.tlsServerName != connection.tlsServerName
            || previous.tlsClientCertificatePath != connection.tlsClientCertificatePath
            || previous.tlsClientKeyPath != connection.tlsClientKeyPath
    }

    func save(_ requested: DatabaseConnection, password: String) async throws {
        QAProbe.action("connection.save.request", ["name": requested.name,
                                                   "host": requested.host + ":" + String(requested.port),
                                                   "user": requested.username,
                                                   "tls": requested.tls.label,
                                                   "writePolicy": requested.effectiveWritePolicy.rawValue,
                                                   "existing": QAField.bool(profiles.contains { $0.id == requested.id })])
        let connection: DatabaseConnection
        do { connection = try requested.validated() }
        catch {
            QAProbe.failure("connection.save.rejected", AppError.describe(error))
            throw error
        }
        let previous = profiles.first { $0.id == connection.id }
        let oldPassword = try CredentialStore.read(for: connection)
        let keepSession = previous?.configurationWithoutTint == connection.configurationWithoutTint && oldPassword == password
        if let previous, !keepSession {
            guard await database.disconnect(previous) else {
                QAProbe.failure("connection.save.rejected", "La conexión está ocupada o se canceló el cambio.")
                throw DatabaseFailure("La conexión está ocupada o se canceló el cambio.")
            }
        }
        var updated = profiles
        if let index = updated.firstIndex(where: { $0.id == connection.id }) { updated[index] = connection }
        else { updated.append(connection) }
        if keepSession {
            try persist(updated)
        } else {
            try CredentialStore.save(password, for: connection)
            do { try persist(updated) }
            catch {
                try? CredentialStore.save(oldPassword, for: connection)
                throw error
            }
            if let previous, Self.endpointChanged(from: previous, to: connection) { forget(previous) }
            database.states[connection.id] = DatabaseState()
        }
        QAProbe.action("connection.save.ok", ["name": connection.name,
                                              "profiles": QAField.count(profiles.count)])
        QAProbe.state("state.connections", ["profiles": QAField.count(profiles.count)])
    }

    func remove(_ connection: DatabaseConnection) {
        QAProbe.action("connection.remove.request", ["name": connection.name])
        Task {
            guard await database.disconnect(connection) else {
                QAProbe.action("connection.remove.cancelled", ["name": connection.name])
                return
            }
            do { try persist(profiles.filter { $0.id != connection.id }) }
            catch { session.errors.report(error)
                return }
            forget(connection)
            database.states.removeValue(forKey: connection.id)
            selections = selections.filter { $0.value != connection.id.uuidString }
            defaults.set(selections, forKey: Self.selectionsKey)
            recentIDs.removeAll { $0 == connection.id }
            defaults.set(recentIDs.map(\.uuidString), forKey: Self.recentKey)
            QAProbe.action("connection.remove.ok", ["name": connection.name,
                                                    "profiles": QAField.count(profiles.count)])
            QAProbe.state("state.connections", ["profiles": QAField.count(profiles.count)])
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
