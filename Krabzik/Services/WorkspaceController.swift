import Foundation
import Observation

/// El estado de la ventana: qué proyecto está abierto, qué documentos, y los servicios
/// que dependen de eso.
///
/// Es el objeto más grande de la app y lo sabe: C5 propone partirlo en
/// `RecentProjectsStore`, `DocumentStore`, `ScriptLibrary` y `ErrorCenter`.
///
/// Lo que no se puede perder al partirlo: **abrir un proyecto no ejecuta nada**. Un
/// `.krabzik` que no se abrió antes entra en solo lectura, y de ahí dependen
/// `runnableProjects`, `mountedProjects`, `scriptURL(_:)` y el gate del agente (S1).
///
/// Confinado al main actor.
@MainActor @Observable
final class WorkspaceController {
    var workspace: Workspace?
    var workspaceURL: URL?
    var selectedProjectID: UUID?
    private(set) var isSwitchingWorkspace = false
    var sidebarVisible = true
    var processesVisible = true
    var commandProject: CodeProject?
    var treeRevision = 0
    let runner = ProcessRunner()
    let database = DatabaseController()
    let agent: AgentController
    @ObservationIgnored let trust: TrustStore
    @ObservationIgnored let recents: RecentProjectsStore
    @ObservationIgnored let errors = ErrorCenter()
    @ObservationIgnored let docs = DocumentStore()
    /// Confianza del proyecto abierto. En `.untrusted` el proyecto es solo lectura:
    /// no se ejecuta nada ni se habilita el agente. Ver docs/specs/S1-proyecto-no-confiable.md.
    private(set) var workspaceTrust: TrustStore.Trust = .trusted
    /// Quién pregunta por la confianza. El valor por defecto **niega**: la interfaz es la que
    /// inyecta el diálogo real, con `WorkspaceController.forApp()`. Así un entorno sin interfaz
    /// —pruebas, CI— nunca queda esperando un modal, y si alguien olvida inyectarlo el proyecto
    /// queda cerrado en vez de confiado.
    /// Los diálogos de la ventana. Por defecto no preguntan ni aceptan nada: los reales
    /// los engancha `forApp()`, igual que `confirmTrust`.
    @ObservationIgnored var dialogs = WorkspaceDialogs()
    @ObservationIgnored var confirmTrust: @MainActor (TrustPrompt) -> TrustDecision = { _ in .cancel }
    @ObservationIgnored var confirmCommand: @MainActor (CommandPrompt) -> CommandDecision = { _ in .cancel }
    @ObservationIgnored private var started = false
    @ObservationIgnored private var pendingOpen: Set<URL> = []
    @ObservationIgnored private let defaults: UserDefaults

    // Reenvíos para las vistas, que le piden todo al controlador.
    var documents: [EditorDocument] { docs.documents }
    var selectedDocument: EditorDocument? { docs.selected }
    var openingFiles: Set<URL> { docs.openingFiles }
    var recentProjects: [URL] { recents.urls }
    var selectedDocumentID: URL? {
        get { docs.selectedID }
        set { docs.selectedID = newValue }
    }
    /// Vacío en solo lectura: así los botones ▶ y el menú Proyecto quedan deshabilitados
    /// sin tener que repetir la condición en cada vista.
    var runnableProjects: [CodeProject] {
        guard workspaceTrust == .trusted else { return [] }
        return workspace?.projects.filter { !$0.command.isEmpty } ?? []
    }

    /// Subproyectos que el explorador monta. En solo lectura se omiten los externos.
    var mountedProjects: [CodeProject] {
        guard let workspace, let workspaceURL else { return [] }
        guard workspaceTrust == .untrusted else { return workspace.projects }
        return workspace.projects.filter { $0.scope(relativeTo: workspaceURL) == .internalToProject }
    }

    var isReadOnly: Bool { workspace != nil && workspaceTrust == .untrusted }
    var selectedProject: CodeProject? {
        runnableProjects.first { $0.id == selectedProjectID } ?? runnableProjects.first
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.trust = TrustStore(defaults: defaults)
        self.agent = AgentController(defaults: defaults)
        self.recents = RecentProjectsStore(defaults: defaults)
        agent.onFilesChanged = { [weak self] scope in self?.refreshAgentFiles(scope) }
        // Lo que el usuario ya venía usando se considera confiable, una sola vez.
        trust.migrateIfNeeded(recentProjects: recents.urls)
    }

    func start(arguments: [String] = ProcessInfo.processInfo.arguments) async {
        guard !started else { return }
        started = true
        if let index = arguments.firstIndex(of: "--workspace"), arguments.indices.contains(index + 1) {
            await openWorkspace(URL(fileURLWithPath: arguments[index + 1]))
        }
    }

    func chooseWorkspace() {
        guard !isSwitchingWorkspace, let url = dialogs.chooseWorkspace() else { return }
        Task { await openWorkspace(url) }
    }

    func createWorkspace() {
        guard !isSwitchingWorkspace, let url = dialogs.createWorkspace() else { return }
        Task {
            guard !isSwitchingWorkspace else { return }
            isSwitchingWorkspace = true
            defer { isSwitchingWorkspace = false }
            guard await prepareToLeave() else { return }
            do {
                let project = Workspace(name: url.deletingPathExtension().lastPathComponent)
                try project.write(to: url)
                trust.markTrusted(url)
                install(project, at: url, trust: .trusted)
            } catch { show(error) }
        }
    }

    func openWorkspace(_ url: URL) async {
        guard !isSwitchingWorkspace, workspaceURL != url.standardizedFileURL else { return }
        isSwitchingWorkspace = true
        defer { isSwitchingWorkspace = false }
        do {
            let project = try await Task.detached(priority: .userInitiated) { try Workspace.read(from: url) }.value
            var decided = trust.trust(for: url)
            if decided == .untrusted {
                switch confirmTrust(prompt(for: project, at: url)) {
                case .cancel: return
                case .readOnly: decided = .untrusted
                case .trust:
                    trust.markTrusted(url)
                    decided = .trusted
                }
            }
            guard await prepareToLeave() else { return }
            install(project, at: url, trust: decided)
        } catch { show(error) }
    }

    func closeWorkspace() async {
        guard !isSwitchingWorkspace, workspace != nil else { return }
        isSwitchingWorkspace = true
        defer { isSwitchingWorkspace = false }
        guard await prepareToLeave() else { return }
        docs.closeAll()
        selectedProjectID = nil
        workspace = nil
        workspaceURL = nil
        workspaceTrust = .trusted
        commandProject = nil
        database.editingConnection = nil
        database.install([])
        treeRevision += 1
    }

    func removeRecentProject(_ url: URL) { recents.forget(url) }

    /// Qué se le muestra al usuario antes de confiar: carpetas externas y comandos,
    /// que es exactamente lo que puede hacer daño.
    private func prompt(for project: Workspace, at url: URL) -> TrustPrompt {
        let external = project.projects
            .filter { $0.scope(relativeTo: url) == .external }
            .map { $0.directory(relativeTo: url).path }
        let commands = project.projects
            .filter { !$0.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { "\($0.name): \($0.command)" }
        return TrustPrompt(name: project.name, path: url.path, externalFolders: external,
                           commands: commands, connectionCount: project.connections.count)
    }

    private func install(_ project: Workspace, at url: URL, trust decided: TrustStore.Trust) {
        docs.closeAll()
        workspace = project
        workspaceURL = url.standardizedFileURL
        workspaceTrust = decided
        database.install(project.connections)
        agent.clearConversation()
        agent.selectedProjectID = nil
        // Para que un repositorio no pueda aportar su propio ejecutable de Codex.
        agent.excludedRoots = project.projects.map { $0.directory(relativeTo: url) }
        agent.visible = agent.visible && decided == .trusted
        Log.workspace.info("""
            proyecto abierto · subproyectos \(project.projects.count, privacy: .public) \
            · conexiones \(project.connections.count, privacy: .public) \
            · \(decided == .trusted ? "confiable" : "solo lectura", privacy: .public)
            """)
        agent.draft = ""
        for item in project.projects { _ = runner.state(for: item.id) }
        selectedProjectID = runnableProjects.first?.id
        treeRevision += 1
        recents.remember(url)
    }

    func addFolders() {
        guard let workspaceURL else { return }
        let urls = dialogs.chooseFolders()
        guard !urls.isEmpty else { return }
        Task {
            let detected = await Task.detached(priority: .userInitiated) {
                urls.map { url -> CodeProject in
                    let (kind, command) = ProjectKind.detect(at: url)
                    let base = workspaceURL.deletingLastPathComponent().path + "/"
                    let path = url.path.hasPrefix(base) ? String(url.path.dropFirst(base.count)) : url.path
                    return CodeProject(name: url.lastPathComponent, path: path, kind: kind, command: command)
                }
            }.value
            guard self.workspaceURL == workspaceURL, var updated = workspace else { return }
            for project in detected {
                let directory = project.directory(relativeTo: workspaceURL)
                if !updated.projects.contains(where: { $0.directory(relativeTo: workspaceURL) == directory }) {
                    updated.projects.append(project)
                    // La carpeta la eligió el usuario en el panel: su comando detectado
                    // queda aprobado, para no pedirle confirmación de algo que pidió.
                    if !project.command.isEmpty {
                        trust.approve(command: project.command, project: project.id, workspaceURL: workspaceURL)
                    }
                }
            }
            persist(updated)
        }
    }

    func updateProject(_ updated: CodeProject) {
        guard var project = workspace, let index = project.projects.firstIndex(where: { $0.id == updated.id }) else { return }
        project.projects[index] = updated
        // Lo que el usuario acaba de escribir no hace falta volver a confirmárselo.
        if let workspaceURL, !updated.command.isEmpty {
            trust.approve(command: updated.command, project: updated.id, workspaceURL: workspaceURL)
        }
        persist(project)
    }

    func removeProject(_ id: UUID) {
        guard var workspace else { return }
        runner.stop(id)
        workspace.projects.removeAll { $0.id == id }
        persist(workspace)
    }

    @discardableResult private func persist(_ updated: Workspace) -> Bool {
        guard let workspaceURL else { return false }
        do {
            try updated.write(to: workspaceURL)
            workspace = updated
            for item in updated.projects { _ = runner.state(for: item.id) }
            treeRevision += 1
            return true
        } catch {
            show(error)
            return false
        }
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

    var selectedDatabase: DatabaseConnection? {
        workspace?.connections.first { $0.id == database.selectedConnectionID }
    }

    func saveConnection(_ connection: DatabaseConnection, password: String) async throws {
        guard var updated = workspace, let workspaceURL else { return }
        let connection = try connection.validated()
        let previous = updated.connections.first { $0.id == connection.id }
        if let previous {
            guard await database.disconnect(previous) else { throw DatabaseFailure("La conexión está ocupada o se canceló el cambio.") }
        }
        let oldPassword = try CredentialStore.read(for: connection)
        if let index = updated.connections.firstIndex(where: { $0.id == connection.id }) { updated.connections[index] = connection }
        else { updated.connections.append(connection) }
        try CredentialStore.save(password, for: connection)
        do { try updated.write(to: workspaceURL) }
        catch {
            try? CredentialStore.save(oldPassword, for: connection)
            throw error
        }
        if let previous, Self.endpointChanged(from: previous, to: connection) {
            do {
                try CredentialStore.remove(for: previous)
            } catch {
                // El endpoint cambió y la credencial vieja quedó en el llavero. No es
                // motivo para abortar el guardado, pero tiene que quedar registrado:
                // es una contraseña que el usuario cree que ya no está.
                Log.security.error("quedó una credencial huérfana en el llavero: \(error.localizedDescription, privacy: .private)")
            }
        }
        await database.client.disconnect(connection.id)
        workspace = updated
        database.states[connection.id] = DatabaseState()
        database.selectedConnectionID = connection.id
    }

    func removeConnection(_ connection: DatabaseConnection) {
        Task {
            guard await database.disconnect(connection), var updated = workspace else { return }
            updated.connections.removeAll { $0.id == connection.id }
            guard persist(updated) else { return }
            do { try CredentialStore.remove(for: connection) } catch { show(error) }
            database.states.removeValue(forKey: connection.id)
            if database.selectedConnectionID == connection.id { database.selectedConnectionID = updated.connections.first?.id }
        }
    }

    func executeSQL() {
        guard let document = selectedDocument, document.language == "SQL", let connection = selectedDatabase else { return }
        database.execute(document, connection: connection)
    }

    /// `nil` cuando la ruta no se puede ofrecer: en solo lectura no se resuelven
    /// rutas externas, que es por donde un `.krabzik` ajeno abriría archivos de cualquier parte.
    func scriptURL(_ path: String) -> URL? {
        guard let workspaceURL else { return nil }
        return ScriptLibrary.url(for: path, workspaceURL: workspaceURL, trust: workspaceTrust)
    }

    func importScripts() {
        guard workspace != nil else { return }
        for url in dialogs.chooseScripts() {
            rememberScript(url)
            openFile(url)
        }
    }

    private func rememberScript(_ url: URL) {
        guard let workspace, let workspaceURL,
              let updated = ScriptLibrary.remembering(url, in: workspace, at: workspaceURL) else { return }
        persist(updated)
    }

    func openFile(_ url: URL) {
        let currentWorkspace = workspaceURL
        Task {
            do {
                try await docs.open(url) { self.workspaceURL == currentWorkspace }
            } catch {
                show(error)
            }
        }
    }

    func createFile(in directory: URL? = nil) {
        guard workspace != nil else { return }
        let suggested = directory
            ?? selectedDocument?.url.deletingLastPathComponent()
            ?? workspaceURL?.deletingLastPathComponent()
        guard let url = dialogs.createFile("nuevo.sql", suggested) else { return }
        do {
            // El panel de guardar ya resolvió la confirmación de sobrescribir.
            try Data().write(to: url, options: .atomic)
            rememberScript(url)
            treeRevision += 1
            openFile(url)
        } catch { show(error) }
    }

    @discardableResult func save(_ document: EditorDocument) async -> Bool {
        do {
            return try await docs.save(document)
        } catch {
            show(error)
            return false
        }
    }

    func saveCopy() {
        guard let document = selectedDocument else { return }
        let suggested = document.url.deletingPathExtension().lastPathComponent
            + "-copia." + document.url.pathExtension
        guard let url = dialogs.saveCopy(suggested, document.url.deletingLastPathComponent()) else { return }
        do {
            try docs.saveCopy(of: document, to: url)
            treeRevision += 1
        } catch {
            show(error)
        }
    }

    func closeDocument(_ document: EditorDocument) {
        Task {
            if document.sqlExecution.isRunning {
                guard dialogs.confirmCancelQuery() else { return }
                database.cancel(document.sqlExecution)
            }
            guard await confirmSave(document) else { return }
            docs.close(document)
        }
    }

    /// `true` si se puede seguir: se guardó, o el usuario decidió descartar.
    private func confirmSave(_ document: EditorDocument) async -> Bool {
        guard document.isDirty else { return true }
        switch dialogs.confirmSave(document.url.lastPathComponent) {
        case .save: return await save(document)
        case .discard: return true
        case .cancel: return false
        }
    }

    func prepareToLeave() async -> Bool {
        if agent.isRunning {
            guard dialogs.confirmStopAgent() else { return false }
            agent.shutdown()
        }
        for document in docs.dirty {
            if !(await confirmSave(document)) { return false }
        }
        if runner.hasActiveProcesses {
            guard dialogs.confirmStopProcesses() else { return false }
            runner.stopAll()
        }
        guard await database.prepareToLeave() else { return false }
        agent.shutdown()
        return true
    }

    func sendToAgent() {
        guard workspaceTrust == .trusted else {
            agent.error = "El proyecto está en solo lectura. Confiá en él para trabajar con Codex."
            return
        }
        guard let workspace, let workspaceURL, !agent.isRunning, !isSwitchingWorkspace else { return }
        let prompt = agent.draft
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Task {
            do {
                let scope = try AgentScope.make(workspace: workspace, url: workspaceURL,
                                                projectID: agent.selectedProjectID,
                                                allowExternal: workspaceTrust == .trusted)
                let dirty = docs.dirty.filter { scope.contains($0.url) }
                if !dirty.isEmpty {
                    guard dialogs.confirmSaveBeforeSending(dirty.map { $0.url.lastPathComponent }) else { return }
                    for document in dirty where !(await save(document)) { return }
                }
                guard self.workspaceURL == workspaceURL, !isSwitchingWorkspace else { return }
                agent.send(prompt, scope: scope)
            } catch { agent.error = error.localizedDescription }
        }
    }

    private func refreshAgentFiles(_ scope: AgentScope) {
        treeRevision += 1
        let currentWorkspace = workspaceURL
        Task {
            await docs.refresh(matching: { scope.contains($0) },
                               stillValid: { self.workspaceURL == currentWorkspace })
        }
    }

    func reloadDocument(_ document: EditorDocument) {
        if document.isDirty, !dialogs.confirmDiscardChanges(document.url.lastPathComponent) {
            return
        }
        do {
            try docs.reload(document)
        } catch {
            show(error)
        }
    }

    func openAgentFile(_ path: String) {
        guard let workspace, let workspaceURL,
              let scope = try? AgentScope.make(workspace: workspace, url: workspaceURL,
                                               projectID: agent.selectedProjectID,
                                               allowExternal: workspaceTrust == .trusted) else { return }
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : scope.cwd.appendingPathComponent(path)
        guard scope.contains(url) else {
            agent.error = "El archivo no pertenece a los subproyectos seleccionados."
            return
        }
        openFile(url)
    }

    func agentFileLabel(_ path: String) -> String {
        guard let workspaceURL else { return path }
        for project in workspace?.projects ?? [] {
            let prefix = project.directory(relativeTo: workspaceURL).resolvingSymlinksInPath().path + "/"
            if path.hasPrefix(prefix) { return project.name + "/" + path.dropFirst(prefix.count) }
        }
        return path
    }

    func startAll() {
        guard let workspaceURL else { return }
        for project in runnableProjects where allowedToRun(project, workspaceURL: workspaceURL) {
            runner.start(project, workspaceURL: workspaceURL)
        }
        processesVisible = true
    }

    func toggleRun(_ project: CodeProject) {
        guard let workspaceURL else { return }
        selectedProjectID = project.id
        let state = runner.state(for: project.id)
        if state.status.active {
            runner.stop(project.id)
        } else {
            guard allowedToRun(project, workspaceURL: workspaceURL) else { return }
            runner.start(project, workspaceURL: workspaceURL)
        }
        processesVisible = true
    }

    /// La puerta vive acá, no en `ProcessRunner`: el controlador es quien conoce el
    /// proyecto y su confianza. Un comando se confirma la primera vez, y de nuevo si
    /// cambia, porque la aprobación se guarda por hash del comando.
    private func allowedToRun(_ project: CodeProject, workspaceURL: URL) -> Bool {
        guard workspaceTrust == .trusted else {
            errors.report(message: "El proyecto está en solo lectura. Confiá en él para ejecutar procesos.")
            return false
        }
        if trust.isApproved(command: project.command, project: project.id, workspaceURL: workspaceURL) {
            return true
        }
        let directory = project.directory(relativeTo: workspaceURL)
        switch confirmCommand(CommandPrompt(project: project.name, command: project.command,
                                            directory: directory.path)) {
        case .cancel:
            return false
        case .once:
            return true
        case .always:
            trust.approve(command: project.command, project: project.id, workspaceURL: workspaceURL)
            return true
        }
    }

    /// Confiar en el proyecto abierto desde la barra de solo lectura.
    func trustCurrentWorkspace() {
        guard let workspaceURL, workspaceTrust == .untrusted else { return }
        trust.markTrusted(workspaceURL)
        workspaceTrust = .trusted
        treeRevision += 1
    }

    /// Suelta las vistas nativas antes de descartar los documentos: el `deinit` de
    /// `EditorSurface` no puede hacerlo bajo las reglas de concurrencia de Swift 6.
    /// Reporta un error para que la ventana lo muestre y el log lo guarde.
    func show(_ error: Error, context: StaticString = #function) {
        errors.report(error, context: context)
    }
}
