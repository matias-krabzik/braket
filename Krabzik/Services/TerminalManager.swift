import AppKit
import Observation

@MainActor @Observable
final class TerminalManager {
    var configurations: [URL: TerminalProjectConfiguration] = [:]
    var sessions: [UUID: TerminalSession] = [:]
    var visible = false
    var error: String?
    @ObservationIgnored var approveClosing: ((String) -> Bool)?
    @ObservationIgnored private let preferences: TerminalPreferences
    @ObservationIgnored private let inspection = TerminalInspection()
    @ObservationIgnored private var monitor: Task<Void, Never>?
    init(defaults: UserDefaults) { preferences = TerminalPreferences(defaults: defaults) }
    func configuration(for url: URL) -> TerminalProjectConfiguration {
        configurations[url.standardizedFileURL] ?? TerminalProjectConfiguration()
    }
    func openProject(_ url: URL) {
        let url = url.standardizedFileURL
        if configurations[url] == nil {
            do { configurations[url] = try preferences.load(url) }
            catch { self.error = error.localizedDescription }
        }
        visible = configuration(for: url).visible
        startMonitoring()
    }
    func sharedEnvironment(for url: URL) throws -> [String: String] {
        let config = try configurations[url.standardizedFileURL] ?? preferences.load(url)
        return Dictionary(uniqueKeysWithValues: config.variables.map { ($0.name, $0.value) })
    }
    func setVisible(_ value: Bool, for url: URL) {
        visible = value
        var config = configuration(for: url)
        config.visible = value
        configurations[url.standardizedFileURL] = config
        persist(url)
    }
    func addTab(_ url: URL) {
        var config = configuration(for: url)
        guard config.tabs.count < 32 else { error = "Máximo 32 terminales por proyecto."
            return }
        let tab = TerminalTabConfiguration(name: "Terminal \(config.tabs.count + 1)",
                                           directory: url.deletingLastPathComponent().path)
        config.tabs.append(tab)
        config.selectedID = tab.id
        configurations[url.standardizedFileURL] = config
        setVisible(true, for: url)
    }
    func select(_ id: UUID, for url: URL) {
        configurations[url.standardizedFileURL]?.selectedID = id
        persist(url)
    }
    func session(for tab: TerminalTabConfiguration, project url: URL) -> TerminalSession {
        if let session = sessions[tab.id] { return session }
        let session = TerminalSession(configuration: tab, workspaceURL: url)
        session.didChange = { [weak self] in self?.persist(url) }
        sessions[tab.id] = session
        return session
    }
    func activate(_ tab: TerminalTabConfiguration, project url: URL, trusted: Bool) -> TerminalSession {
        let session = session(for: tab, project: url)
        if trusted { session.start(projectVariables: configuration(for: url).variables) }
        return session
    }
    func close(_ tab: TerminalTabConfiguration, project url: URL) async {
        if let session = sessions[tab.id] {
            await refresh(session)
            if session.hasWork && !confirmStop("Cerrar \(tab.name)") { return }
            session.stop()
        }
        var config = configuration(for: url)
        config.tabs.removeAll { $0.id == tab.id }
        if config.selectedID == tab.id { config.selectedID = config.tabs.last?.id }
        configurations[url.standardizedFileURL] = config
        persist(url)
        sessions.removeValue(forKey: tab.id)
        preferences.removeValues(tab.variables)
    }
    func saveEnvironment(_ variables: [TerminalEnvironmentVariable], project url: URL,
                         tab: TerminalTabConfiguration?) throws {
        try TerminalEnvironment.validate(variables)
        try preferences.saveValues(variables)
        var config = configuration(for: url)
        let old: [TerminalEnvironmentVariable]
        if var tab, let index = config.tabs.firstIndex(where: { $0.id == tab.id }) {
            old = config.tabs[index].variables
            tab.variables = variables
            config.tabs[index] = tab
            sessions[tab.id]?.configuration = tab
        } else {
            old = config.variables
            config.variables = variables
        }
        configurations[url.standardizedFileURL] = config
        try preferences.save(config, for: url)
        preferences.removeValues(old.filter { previous in !variables.contains { $0.id == previous.id } })
    }
    func updateTab(_ tab: TerminalTabConfiguration, project url: URL) {
        guard let index = configurations[url.standardizedFileURL]?.tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        configurations[url.standardizedFileURL]?.tabs[index] = tab
        sessions[tab.id]?.configuration = tab
        persist(url)
    }
    func restart(_ tab: TerminalTabConfiguration, project url: URL) async {
        if let session = sessions[tab.id] {
            await refresh(session)
            if session.hasWork && !confirmStop("Reiniciar \(tab.name)") { return }
            session.stop()
        }
        sessions.removeValue(forKey: tab.id)
        _ = activate(tab, project: url, trusted: true)
    }
    func prepareToQuit() async -> Bool {
        for session in sessions.values { await refresh(session) }
        let active = sessions.values.filter(\.hasWork)
        return active.isEmpty || confirmStop("Salir de Braket · \(active.count) terminales con procesos activos")
    }
    func stopAll() {
        for session in sessions.values { session.stop() }
        monitor?.cancel()
        monitor = nil
    }
    private func confirmStop(_ title: String) -> Bool {
        if let approveClosing { return approveClosing(title) }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "Hay procesos o servicios activos. Se detendrán al cerrar esta sesión."
        alert.addButton(withTitle: "Cancelar")
        alert.addButton(withTitle: "Detener y cerrar")
        alert.alertStyle = .warning
        return alert.runModal() == .alertSecondButtonReturn
    }
    private func persist(_ url: URL) {
        var config = configuration(for: url)
        for index in config.tabs.indices {
            if let session = sessions[config.tabs[index].id] { config.tabs[index].directory = session.currentDirectory }
        }
        configurations[url.standardizedFileURL] = config
        do { try preferences.save(config, for: url) } catch { self.error = error.localizedDescription }
    }
    private func refresh(_ session: TerminalSession) async {
        guard session.running, let pid = session.view?.process.shellPid, pid > 0 else { return }
        let snapshot = await inspection.snapshot(pid: pid)
        session.children = snapshot.children
        if let directory = snapshot.directory, directory != session.currentDirectory {
            session.currentDirectory = directory
            persist(session.workspaceURL)
        }
    }
    private func startMonitoring() {
        guard monitor == nil else { return }
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                for session in Array(sessions.values) { await refresh(session) }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }
}

extension WorkspaceController {
    func toggleTerminal() {
        guard let url = workspaceURL else { return }
        let show = !terminals.visible
        if show, terminals.configuration(for: url).tabs.isEmpty, !isReadOnly { terminals.addTab(url) }
        else { terminals.setVisible(show, for: url) }
        if show { workflowVisible = false }
    }
}
