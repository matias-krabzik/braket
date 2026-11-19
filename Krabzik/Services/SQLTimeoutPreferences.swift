import Foundation
import Observation

/// El límite es por sentencia. La preferencia del archivo es local a este proyecto;
/// sin una preferencia propia, los cambios de proyecto o aplicación se heredan en vivo.
@MainActor @Observable final class SQLTimeoutPreferences {
    static let key = "sql.fileTimeouts.v1"
    private let defaults: UserDefaults
    private let settings: AppSettings
    private let session: WorkspaceSession
    private var overrides: [String: Int]

    init(defaults: UserDefaults, settings: AppSettings, session: WorkspaceSession) {
        self.defaults = defaults
        self.settings = settings
        self.session = session
        overrides = (defaults.dictionary(forKey: Self.key) as? [String: Int] ?? [:]).filter { (1...3600).contains($0.value) }
    }
    private var project: String { session.url?.standardizedFileURL.path ?? "" }
    private func identity(project: String, path: String) -> String {
        // Prefijos de longitud evitan colisiones aunque las rutas contengan separadores.
        String(project.utf8.count) + ":" + project + path
    }
    private func persist() { defaults.set(overrides, forKey: Self.key) }

    func bind(_ document: EditorDocument) {
        guard document.language == "SQL" else { return }
        let execution = document.sqlExecution
        let key = identity(project: project, path: document.url.standardizedFileURL.path)
        guard execution.timeoutBindingKey != key else { return }
        if let old = execution.timeoutBindingKey, execution.timeoutBindingProject == project,
           execution.hasCustomTimeout, overrides[key] == nil {
            overrides[key] = execution.timeoutSeconds
            overrides.removeValue(forKey: old)
            persist()
        }
        let inMemory = execution.timeoutBindingKey == nil && execution.hasCustomTimeout ? execution.timeoutSeconds : nil
        execution.timeoutBindingKey = key
        execution.timeoutBindingProject = project
        execution.inheritedTimeout = { [weak self] in self?.session.workspace?.sqlTimeoutSeconds
            ?? self?.settings.defaultSQLTimeoutSeconds ?? 60 }
        execution.inheritedTimeoutSource = { [weak self] in self?.session.workspace?.sqlTimeoutSeconds == nil ? "Aplicación" : "Proyecto" }
        execution.loadTimeout(overrides[key] ?? inMemory)
        execution.saveTimeout = { [weak self] seconds in
            self?.overrides[key] = seconds
            self?.persist()
        }
    }

    func relocateProject(from source: URL, to destination: URL) {
        let old = source.standardizedFileURL.path, new = destination.standardizedFileURL.path
        let prefix = String(old.utf8.count) + ":" + old
        for key in Array(overrides.keys) where key.hasPrefix(prefix) {
            let path = String(key.dropFirst(prefix.count))
            overrides[identity(project: new, path: path)] = overrides.removeValue(forKey: key)
        }
        persist()
    }
}
