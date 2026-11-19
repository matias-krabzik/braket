import Foundation
import Observation

/// Perfiles locales con pertenencia por proyecto y un catálogo optativo de compartidas.
/// Las contraseñas permanecen en el llavero; los proyectos no importan perfiles ajenos automáticamente.
@MainActor @Observable
final class ConnectionStore {
    static let profilesKey = "mysql.globalConnections.v1"
    static let selectionsKey = "mysql.scriptConnections.v1"
    static let recentKey = "mysql.recentConnections.v1"
    private let session: WorkspaceSession
    private let database: DatabaseController
    private let defaults: UserDefaults
    static let catalogKey = "mysql.projectConnections.v2"
    private struct Placement: Codable {
        var shared: Bool
        var projects: Set<String>
    }
    private struct Catalog: Codable {
        var profiles: [DatabaseConnection]
        var placements: [String: Placement]
        var imports: [String: UUID]
    }
    private(set) var allProfiles: [DatabaseConnection]
    private var placements: [String: Placement]
    private var imports: [String: UUID]
    private let loadFailed: Bool
    private var recentScopes: [String: [String]]
    private var scope: String { session.url?.standardizedFileURL.path ?? "__standalone__" }
    var hasProject: Bool { session.url != nil }
    var profiles: [DatabaseConnection] {
        allProfiles.filter { connection in
            if !hasProject { return isShared(connection) }
            return placements[connection.id.uuidString]?.projects.contains(scope) == true
        }
    }
    var sharedProfiles: [DatabaseConnection] { allProfiles.filter { isShared($0) } }
    var availableShared: [DatabaseConnection] {
        let installed = Set(profiles.map(\.id))
        return sharedProfiles.filter { !installed.contains($0.id) }
    }
    func isShared(_ connection: DatabaseConnection) -> Bool { placements[connection.id.uuidString]?.shared ?? true }
    func otherProjectCount(_ connection: DatabaseConnection) -> Int {
        placements[connection.id.uuidString]?.projects.filter { $0 != scope && $0 != "__standalone__" }.count ?? 0
    }
    private var selections: [String: String]
    var recentIDs: [UUID] {
        (recentScopes[scope] ?? defaults.stringArray(forKey: Self.recentKey) ?? []).compactMap(UUID.init(uuidString:))
    }
    private var migrated: Set<String>

    init(session: WorkspaceSession, database: DatabaseController, defaults: UserDefaults = .standard) {
        self.session = session
        self.database = database
        self.defaults = defaults
        var loadError: Error?
        if let data = defaults.data(forKey: Self.catalogKey) {
            do {
                let catalog = try JSONDecoder().decode(Catalog.self, from: data)
                allProfiles = catalog.profiles
                placements = catalog.placements
                imports = catalog.imports
            } catch {
                allProfiles = []
                placements = [:]
                imports = [:]
                loadError = error
            }
        } else {
            allProfiles = defaults.data(forKey: Self.profilesKey)
                .flatMap { try? JSONDecoder().decode([DatabaseConnection].self, from: $0) } ?? []
            placements = [:]
            imports = [:]
        }
        selections = defaults.dictionary(forKey: Self.selectionsKey) as? [String: String] ?? [:]
        recentScopes = defaults.dictionary(forKey: "mysql.projectRecents.v2") as? [String: [String]] ?? [:]
        migrated = Set(defaults.stringArray(forKey: "mysql.migratedProfiles.v1") ?? [])
        loadFailed = loadError != nil
        if let loadError { session.errors.report(loadError) }
        for connection in allProfiles { _ = database.state(connection.id) }
    }

    /// Cada proyecto conserva su selección y sus recientes, incluso para el mismo archivo.
    private func selectionKey(_ url: URL) -> String { scope + "|" + url.standardizedFileURL.path }
    func relocateScript(from source: URL, to destination: URL) {
        let old = source.standardizedFileURL.path
        let new = destination.standardizedFileURL.path
        for key in Array(selections.keys) where key == old || key.hasSuffix("|" + old) {
            let value = selections.removeValue(forKey: key)
            selections[String(key.dropLast(old.count)) + new] = value
        }
        defaults.set(selections, forKey: Self.selectionsKey)
    }

    func persistDraftSelection(_ document: EditorDocument) {
        guard !document.isDraft, let id = document.draftConnectionID else { return }
        selections[selectionKey(document.url)] = id.uuidString
        document.draftConnectionID = nil
        defaults.set(selections, forKey: Self.selectionsKey)
    }

    func selected(for document: EditorDocument) -> DatabaseConnection? {
        guard let id = document.draftConnectionID?.uuidString ?? selections[selectionKey(document.url)]
            ?? selections[document.url.standardizedFileURL.path] else { return nil }
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
            var recent = recentIDs.filter { $0 != id }
            recent.insert(id, at: 0)
            recentScopes[scope] = Array(recent.prefix(3)).map(\.uuidString)
            defaults.set(recentScopes, forKey: "mysql.projectRecents.v2")
        }
        if document.isDraft { document.draftConnectionID = id
            return }
        document.draftConnectionID = nil
        selections[selectionKey(document.url)] = id?.uuidString ?? ""
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
            guard imports[key] == nil else { continue }
            do {
                var connection = try original.validated()
                var updated = allProfiles
                if migrated.contains(key) {
                    guard let existing = allProfiles.first(where: { candidate in
                        var sameID = candidate
                        sameID.id = original.id
                        return sameID == original
                    }) else { continue }
                    connection = existing
                } else if let existing = allProfiles.first(where: { $0.id == original.id }), existing != original {
                    connection.id = UUID()
                    let password = try CredentialStore.read(for: original)
                    if !password.isEmpty { try CredentialStore.save(password, for: connection) }
                }
                if !updated.contains(where: { $0.id == connection.id }) { updated.append(connection) }
                var placement = placements[connection.id.uuidString] ?? Placement(shared: true, projects: [])
                placement.projects.insert(scope)
                var next = placements
                next[connection.id.uuidString] = placement
                var mapped = imports
                mapped[key] = connection.id
                try persist(updated, placements: next, imports: mapped)
                _ = database.state(connection.id)
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

    func save(_ requested: DatabaseConnection, password: String, shared: Bool? = nil) async throws {
        guard !session.isReadOnly else { throw DatabaseFailure("El proyecto está en solo lectura.") }
        let owner = scope
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
        let previous = allProfiles.first { $0.id == connection.id }
        guard previous == nil || profiles.contains(where: { $0.id == connection.id }) else {
            throw DatabaseFailure("Agregá la conexión desde Compartidas antes de editarla.")
        }
        var placement = placements[connection.id.uuidString]
            ?? Placement(shared: previous != nil || !hasProject, projects: [])
        placement.shared = !hasProject || (shared ?? placement.shared)
        if !placement.shared && placement.projects.contains(where: { $0 != owner && $0 != "__standalone__" }) {
            throw DatabaseFailure("La conexión se usa en otros proyectos. Duplicala para crear una copia privada.")
        }
        placement.projects.insert(owner)
        var next = placements
        next[connection.id.uuidString] = placement
        let oldPassword = try CredentialStore.read(for: connection)
        let keepSession = previous?.configurationWithoutTint == connection.configurationWithoutTint && oldPassword == password
        if let previous, !keepSession {
            guard await database.disconnect(previous) else {
                QAProbe.failure("connection.save.rejected", "La conexión está ocupada o se canceló el cambio.")
                throw DatabaseFailure("La conexión está ocupada o se canceló el cambio.")
            }
        }
        // El proyecto puede cambiar mientras se espera el cierre de una sesión.
        // Combinar con la pertenencia más reciente, conservando el proyecto que inició la edición.
        var latest = placements[connection.id.uuidString] ?? placement
        latest.shared = placement.shared
        latest.projects.insert(owner)
        next = placements
        next[connection.id.uuidString] = latest
        var updated = allProfiles
        if let index = updated.firstIndex(where: { $0.id == connection.id }) { updated[index] = connection }
        else { updated.append(connection) }
        if keepSession {
            try persist(updated, placements: next)
        } else {
            try CredentialStore.save(password, for: connection)
            do { try persist(updated, placements: next) }
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

    func addShared(_ connection: DatabaseConnection) throws {
        guard !session.isReadOnly, isShared(connection), allProfiles.contains(where: { $0.id == connection.id }) else {
            throw DatabaseFailure("No se puede agregar esta conexión compartida.")
        }
        var next = placements
        var placement = next[connection.id.uuidString] ?? Placement(shared: true, projects: [])
        placement.projects.insert(scope)
        next[connection.id.uuidString] = placement
        try persist(allProfiles, placements: next)
        _ = database.state(connection.id)
    }

    func relocateProject(from source: URL, to destination: URL) {
        let old = source.standardizedFileURL.path, new = destination.standardizedFileURL.path
        var next = placements
        for id in next.keys where next[id]?.projects.contains(old) == true {
            next[id]?.projects.remove(old)
            next[id]?.projects.insert(new)
        }
        var mapped = imports
        for key in Array(mapped.keys) where key.hasPrefix(old + "|") {
            mapped[new + key.dropFirst(old.count)] = mapped.removeValue(forKey: key)
        }
        do { try persist(allProfiles, placements: next, imports: mapped) }
        catch { session.errors.report(error)
            return }
        for key in Array(selections.keys) where key.hasPrefix(old + "|") {
            selections[new + key.dropFirst(old.count)] = selections.removeValue(forKey: key)
        }
        defaults.set(selections, forKey: Self.selectionsKey)
        recentScopes[new] = recentScopes.removeValue(forKey: old)
        defaults.set(recentScopes, forKey: "mysql.projectRecents.v2")
    }

    func remove(_ connection: DatabaseConnection) {
        guard !session.isReadOnly, profiles.contains(where: { $0.id == connection.id }) else { return }
        let owner = scope, global = !hasProject
        QAProbe.action("connection.remove.request", ["name": connection.name])
        Task {
            guard await database.disconnect(connection) else {
                QAProbe.action("connection.remove.cancelled", ["name": connection.name])
                return
            }
            var next = placements
            var placement = next[connection.id.uuidString] ?? Placement(shared: true, projects: [])
            placement.projects.remove(owner)
            let delete = global || (!placement.shared && placement.projects.isEmpty)
            next[connection.id.uuidString] = delete ? nil : placement
            do { try persist(delete ? allProfiles.filter { $0.id != connection.id } : allProfiles, placements: next) }
            catch { session.errors.report(error)
                return }
            if delete { forget(connection)
                database.states.removeValue(forKey: connection.id) }
            // Tombstones impiden restaurar una selección global anterior al volver a agregarla.
            for key in Array(selections.keys) where selections[key] == connection.id.uuidString {
                if delete || key.hasPrefix(owner + "|") { selections[key] = "" }
                else if !key.contains("|") { selections[owner + "|" + key] = "" }
            }
            defaults.set(selections, forKey: Self.selectionsKey)
            for key in Array(recentScopes.keys) where delete || key == owner {
                recentScopes[key]?.removeAll { $0 == connection.id.uuidString }
            }
            defaults.set(recentScopes, forKey: "mysql.projectRecents.v2")
            QAProbe.action("connection.remove.ok", ["name": connection.name, "profiles": QAField.count(profiles.count)])
            QAProbe.state("state.connections", ["profiles": QAField.count(profiles.count)])
        }
    }

    private func persist(_ updated: [DatabaseConnection], placements next: [String: Placement]? = nil,
                         imports mapped: [String: UUID]? = nil) throws {
        guard !loadFailed else { throw DatabaseFailure("El catálogo no pudo leerse. Se conservó sin sobrescribirlo.") }
        let catalog = Catalog(profiles: updated, placements: next ?? placements, imports: mapped ?? imports)
        let data = try JSONEncoder().encode(catalog)
        defaults.set(data, forKey: Self.catalogKey)
        allProfiles = updated
        placements = catalog.placements
        imports = catalog.imports
    }

    private func forget(_ connection: DatabaseConnection) {
        do { try CredentialStore.remove(for: connection) }
        catch { session.errors.report(error) }
    }
}
