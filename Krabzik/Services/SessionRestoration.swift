import Foundation

/// Rutas y selección de la última salida confirmada. No guarda texto sin guardar,
/// credenciales, conexiones abiertas ni procesos para ejecutar al iniciar.
struct SavedWorkspaceState: Codable, Equatable {
    var version = 1
    let workspaceURL: URL
    let openFiles: [URL]
    let selectedFile: URL?
    let selectedProjectID: UUID?
    let sidebarVisible: Bool
    let processesVisible: Bool
}

@MainActor
final class SessionRestoration {
    static let key = "lastWorkspaceState"
    private let defaults: UserDefaults

    init(defaults: UserDefaults) { self.defaults = defaults }

    func load() -> SavedWorkspaceState? {
        guard let data = defaults.data(forKey: Self.key), data.count <= 1_048_576,
              let state = try? JSONDecoder().decode(SavedWorkspaceState.self, from: data),
              state.version == 1, state.workspaceURL.isFileURL,
              state.openFiles.allSatisfy(\.isFileURL) else { return nil }
        return state
    }

    func save(_ state: SavedWorkspaceState?) {
        guard let state else {
            clear()
            return
        }
        do {
            defaults.set(try JSONEncoder().encode(state), forKey: Self.key)
        } catch {
            Log.workspace.error("No se pudo guardar la sesión: \(error.localizedDescription, privacy: .public)")
        }
    }

    func clear() { defaults.removeObject(forKey: Self.key) }
}

extension WorkspaceController {
    func captureSessionState() -> SavedWorkspaceState? {
        guard let workspaceURL else { return nil }
        return SavedWorkspaceState(workspaceURL: workspaceURL, openFiles: documents.map(\.url),
                                   selectedFile: selectedDocumentID, selectedProjectID: selectedProjectID,
                                   sidebarVisible: sidebarVisible, processesVisible: processesVisible)
    }

    func saveSessionState(_ state: SavedWorkspaceState?) {
        restoration.save(settings.restoreLastState ? state : nil)
    }

    func restoreSession(_ state: SavedWorkspaceState) async {
        await openWorkspace(state.workspaceURL)
        guard workspaceURL == state.workspaceURL.standardizedFileURL, requestedWorkspaceURL == nil else { return }
        var unavailable = 0
        for url in state.openFiles {
            guard workspaceURL == state.workspaceURL.standardizedFileURL, requestedWorkspaceURL == nil else { return }
            if isReadOnly, pathScope(url.path, relativeTo: state.workspaceURL) == .external { continue }
            do {
                try await docs.open(url) {
                    self.workspaceURL == state.workspaceURL.standardizedFileURL && self.requestedWorkspaceURL == nil
                }
            } catch {
                unavailable += 1
            }
        }
        guard workspaceURL == state.workspaceURL.standardizedFileURL, requestedWorkspaceURL == nil else { return }
        if let selected = state.selectedFile, docs.contains(selected) { selectedDocumentID = selected.standardizedFileURL }
        if let selected = state.selectedProjectID, workspace?.projects.contains(where: { $0.id == selected }) == true {
            selectedProjectID = selected
        }
        sidebarVisible = state.sidebarVisible
        processesVisible = state.processesVisible
        if unavailable > 0 {
            errors.report(message: "Se recuperó el proyecto, pero \(unavailable) archivos no están disponibles o no se pueden leer.")
        }
    }
}
