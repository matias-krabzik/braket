import CryptoKit
import Foundation

/// Índice de sesiones de Braket. Codex conserva el historial; acá solo se guardan
/// identificadores, títulos y borradores. Lo posee AgentController en el main actor.
struct AgentSessionRecord: Codable, Identifiable, Equatable {
    var id = UUID()
    var title = "Nueva sesión"
    var threadID: String?
    var projectID: UUID?
    var roots: [URL] = []
    var draft = ""
    var updatedAt = Date()
}

/// Separa el índice por archivo de proyecto, incluso cuando dos proyectos tienen
/// el mismo nombre o comparten carpetas. Acceso confinado al main actor.
@MainActor
struct AgentSessionStore {
    let defaults: UserDefaults

    private func key(_ workspace: URL) -> String {
        let path = workspace.standardizedFileURL.resolvingSymlinksInPath().path
        let digest = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        return "agentSessions.v1." + digest
    }

    func load(_ workspace: URL) -> [AgentSessionRecord] {
        guard let data = defaults.data(forKey: key(workspace)) else { return [] }
        do { return try JSONDecoder().decode([AgentSessionRecord].self, from: data) }
        catch {
            Log.agent.error("No se pudo leer el índice de sesiones: \(error.localizedDescription, privacy: .private)")
            return []
        }
    }

    func save(_ sessions: [AgentSessionRecord], workspace: URL) {
        do { defaults.set(try JSONEncoder().encode(sessions), forKey: key(workspace)) }
        catch { Log.agent.error("No se pudo guardar el índice de sesiones: \(error.localizedDescription, privacy: .private)") }
    }
}
