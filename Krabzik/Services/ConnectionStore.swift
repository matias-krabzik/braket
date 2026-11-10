import Foundation

/// Las conexiones MySQL declaradas en el proyecto, y su contraseña en el llavero.
///
/// Las dos cosas van juntas porque guardar una conexión es una operación de dos destinos
/// que tiene que quedar consistente: la contraseña va al llavero y el perfil al
/// `.krabzik`. Si la escritura del archivo falla, acá se restaura la contraseña anterior,
/// y si el endpoint cambió se borra la credencial que quedó huérfana. Repartido entre dos
/// tipos, ese orden se pierde.
///
/// Confinado al main actor. Ver docs/specs/C5-dividir-workspacecontroller.md.
@MainActor
final class ConnectionStore {
    private let session: WorkspaceSession
    private let database: DatabaseController

    init(session: WorkspaceSession, database: DatabaseController) {
        self.session = session
        self.database = database
    }

    /// La conexión seleccionada en el panel, si sigue estando en el proyecto.
    var selected: DatabaseConnection? {
        session.workspace?.connections.first { $0.id == database.selectedConnectionID }
    }

    /// Reemplaza las conexiones vivas al abrir o cerrar un proyecto. Cierra la hoja de
    /// edición: la conexión que estaba abierta ahí es de otro proyecto.
    func install(_ connections: [DatabaseConnection]) {
        database.editingConnection = nil
        database.install(connections)
    }

    /// Si la credencial guardada del perfil anterior ya no sirve para el nuevo.
    ///
    /// La cuenta del llavero incluye host, puerto, usuario y modo de TLS (ver
    /// `CredentialStore`), así que cambiar cualquiera de los cuatro deja la contraseña
    /// vieja huérfana. El host se compara sin distinguir mayúsculas porque los nombres de
    /// dominio no las distinguen, y el llavero guarda el host ya en minúsculas.
    static func endpointChanged(from previous: DatabaseConnection, to connection: DatabaseConnection) -> Bool {
        previous.host.lowercased() != connection.host.lowercased()
            || previous.port != connection.port
            || previous.username != connection.username
            || previous.tls != connection.tls
    }

    /// Guarda el perfil y su contraseña. Desconecta primero la versión anterior: cambiar
    /// el endpoint de una conexión en uso dejaría una sesión apuntando a otro servidor.
    func save(_ connection: DatabaseConnection, password: String) async throws {
        guard var updated = session.workspace, session.url != nil else { return }
        let connection = try connection.validated()
        let previous = updated.connections.first { $0.id == connection.id }
        if let previous {
            guard await database.disconnect(previous) else {
                throw DatabaseFailure("La conexión está ocupada o se canceló el cambio.")
            }
        }
        let oldPassword = try CredentialStore.read(for: connection)
        if let index = updated.connections.firstIndex(where: { $0.id == connection.id }) {
            updated.connections[index] = connection
        } else {
            updated.connections.append(connection)
        }
        try CredentialStore.save(password, for: connection)
        do { try session.save(updated) }
        catch {
            try? CredentialStore.save(oldPassword, for: connection)
            throw error
        }
        if let previous, Self.endpointChanged(from: previous, to: connection) { forget(previous) }
        await database.client.disconnect(connection.id)
        database.states[connection.id] = DatabaseState()
        database.selectedConnectionID = connection.id
    }

    func remove(_ connection: DatabaseConnection) {
        Task {
            guard await database.disconnect(connection), var updated = session.workspace else { return }
            updated.connections.removeAll { $0.id == connection.id }
            guard session.write(updated) else { return }
            do { try CredentialStore.remove(for: connection) } catch { session.errors.report(error) }
            database.states.removeValue(forKey: connection.id)
            if database.selectedConnectionID == connection.id {
                database.selectedConnectionID = updated.connections.first?.id
            }
        }
    }

    /// Borra del llavero una credencial que ya no le sirve a nadie.
    ///
    /// No aborta nada si falla: el perfil ya se guardó. Pero queda registrado, porque es
    /// una contraseña que el usuario cree que ya no está.
    private func forget(_ connection: DatabaseConnection) {
        do {
            try CredentialStore.remove(for: connection)
        } catch {
            Log.security.error("quedó una credencial huérfana en el llavero: \(error.localizedDescription, privacy: .private)")
        }
    }
}
