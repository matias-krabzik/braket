import CryptoKit
import Foundation

/// Un `.krabzik` es JSON editable que trae rutas y **comandos de shell arbitrarios**.
/// Abrir uno recibido de un tercero no puede ejecutar nada, ni dar acceso de escritura
/// al agente, hasta que el usuario lo apruebe viendo qué aprueba.
/// Ver docs/specs/S1-proyecto-no-confiable.md.
@MainActor final class TrustStore {
    /// Si el usuario ya dijo que confía en este proyecto.
    enum Trust: Equatable {
        case trusted
        case untrusted
    }

    /// Claves de `UserDefaults`. Juntas para que se vea qué persiste el modelo de
    /// confianza: nada más que rutas confiadas y hashes de comandos aprobados.
    private enum Keys {
        static let workspaces = "trustedWorkspaces"
        static let commands = "approvedCommands"
        static let migration = "trustMigrationDone"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Proyectos

    func trust(for workspaceURL: URL) -> Trust {
        trustedPaths.contains(key(for: workspaceURL)) ? .trusted : .untrusted
    }

    func markTrusted(_ workspaceURL: URL) {
        var paths = trustedPaths
        paths.insert(key(for: workspaceURL))
        defaults.set(Array(paths), forKey: Keys.workspaces)
        Log.security.notice("proyecto marcado como confiable: \(workspaceURL.path, privacy: .private)")
    }

    func forget(_ workspaceURL: URL) {
        var paths = trustedPaths
        paths.remove(key(for: workspaceURL))
        defaults.set(Array(paths), forKey: Keys.workspaces)
    }

    /// Los proyectos que el usuario ya venía usando se consideran confiables una sola
    /// vez, al actualizar. Sin esto, el flujo normal se rompería de golpe.
    func migrateIfNeeded(recentProjects: [URL]) {
        guard !defaults.bool(forKey: Keys.migration) else { return }
        for url in recentProjects { markTrusted(url) }
        defaults.set(true, forKey: Keys.migration)
    }

    // MARK: - Comandos

    /// La aprobación es por comando, no por subproyecto: editar el comando la revoca.
    func isApproved(command: String, project: UUID, workspaceURL: URL) -> Bool {
        approvedCommands.contains(commandKey(command, project, workspaceURL))
    }

    func approve(command: String, project: UUID, workspaceURL: URL) {
        var approved = approvedCommands
        approved.insert(commandKey(command, project, workspaceURL))
        defaults.set(Array(approved), forKey: Keys.commands)
        Log.security.notice("comando aprobado: \(command, privacy: .private)")
    }

    // MARK: - Interno

    private var trustedPaths: Set<String> {
        Set(defaults.stringArray(forKey: Keys.workspaces) ?? [])
    }

    private var approvedCommands: Set<String> {
        Set(defaults.stringArray(forKey: Keys.commands) ?? [])
    }

    private func key(for workspaceURL: URL) -> String {
        workspaceURL.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func commandKey(_ command: String, _ project: UUID, _ workspaceURL: URL) -> String {
        let digest = SHA256.hash(data: Data(command.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(key(for: workspaceURL))|\(project.uuidString)|\(hex)"
    }
}

/// Lo que se le muestra al usuario antes de confiar en un proyecto.
struct TrustPrompt: Sendable {
    let name: String
    let path: String
    let externalFolders: [String]
    let commands: [String]
    let connectionCount: Int
}

/// Lo que el usuario decidió sobre un proyecto que no había abierto antes.
enum TrustDecision: Sendable {
    case cancel
    case readOnly
    case trust
}

/// Lo que se le muestra antes de ejecutar un comando por primera vez.
struct CommandPrompt: Sendable {
    let project: String
    let command: String
    let directory: String
}

/// Lo que el usuario decidió sobre un comando que nunca se ejecutó en este proyecto.
enum CommandDecision: Sendable {
    case cancel
    case once
    case always
}
