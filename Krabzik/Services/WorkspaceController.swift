import Foundation
import Observation

/// El estado de la ventana: qué proyecto está abierto, y cómo se recablean los servicios
/// cuando eso cambia.
///
/// Coordina; no decide. Cada decisión vive en el colaborador que es dueño de ella:
/// `WorkspaceSession` (qué proyecto, dónde, con qué confianza, y el único camino de
/// escritura), `ProjectLibrary` (subproyectos y el permiso para ejecutar su comando),
/// `ConnectionStore` (conexiones y llavero), `FileCommands` (archivos y pestañas),
/// `AgentBridge` (Codex), más `DocumentStore`, `RecentProjectsStore` y `ErrorCenter`.
///
/// Lo que queda acá es lo que necesita a todos a la vez: abrir, crear y cerrar un
/// proyecto, y `prepareToLeave()`, que es el orden en que se le pregunta al usuario antes
/// de dejar lo que está abierto.
///
/// Lo que no se puede perder: **abrir un proyecto no ejecuta nada**. Un `.kzk` que no
/// se abrió antes entra en solo lectura, y de ahí dependen los gates de la sesión (S1).
///
/// Confinado al main actor. Ver docs/specs/C5-dividir-workspacecontroller.md.
@MainActor @Observable
final class WorkspaceController {
    let settings: AppSettings
    let sqlTimeouts: SQLTimeoutPreferences
    @ObservationIgnored let restoration: SessionRestoration
    private(set) var isRestoringSession = false
    @ObservationIgnored private(set) var requestedWorkspaceURL: URL?
    @ObservationIgnored private var requestedPixelArtURLs: [URL] = []
    private(set) var openWorkspaceURLs: [URL] = []
    var openWorkspaceModels: [URL: Workspace] = [:]
    @ObservationIgnored var suspendedDocuments: [URL: DocumentStore.OpenDocuments] = [:]
    @ObservationIgnored var workspaceStates: [URL: SavedWorkspaceState] = [:]
    var selectedProjectID: UUID?
    var newFileRequest: UUID?
    var newFileDirectory: URL?
    var newPixelArtRequest: UUID?
    var newPixelArtDirectory: URL?
    var fileOperation: FileOperationStatus?
    var sidebarVisible = true
    var processesVisible = false
    var pixelProcessesVisible = false
    var commandProject: CodeProject?
    var closingProjectURL: URL?
    var showingProjectWizard = false
    let settingsClose = SettingsCloseCoordinator()
    var showingSettings = false
    var showingProjectSettings = false
    let runner = ProcessRunner()
    let terminals: TerminalManager
    var processManager: ProcessManagerPresentation
    let workflows = WorkflowController()
    var outputVisible = false {
        didSet { if outputVisible { workflowVisible = false } }
    }
    var sqlResultsDocumentID: URL?
    var sqlResultsDocument: EditorDocument? {
        if let selectedDocument, selectedDocument.language == "SQL" { return selectedDocument }
        return documents.first { $0.id == sqlResultsDocumentID } ?? documents.last { $0.language == "SQL" }
    }
    var workflowVisible = false {
        didSet { if workflowVisible {
            gitChanges.tabVisible = false
            outputVisible = false
        } }
    }
    func refreshGitChanges() async {
        guard let workspaceURL else { return }
        let directories = mountedProjects.map { $0.directory(relativeTo: workspaceURL) }
        await gitChanges.refresh(directories: directories + [workspaceURL.deletingLastPathComponent()])
    }
    func showOutput() {
        database.resultsVisible = true
        outputVisible = true
    }
    var workflowTabOpen = false
    var workflowRoot: URL {
        workspace?.projects.first?.directory(relativeTo: workspaceURL ?? URL(fileURLWithPath: "/")) ?? workspaceURL?
        .deletingLastPathComponent() ?? URL(fileURLWithPath: "/") }
    func openWorkflowFile(_ path: URL) {
        guard path.lastPathComponent.hasSuffix(".flow.json"), let workspaceURL else { return }
        workflows.configure(workspaceURL, root: workflowRoot, selectedFile: path)
        workflowTabOpen = true
        workflowVisible = true
    }

    let gitChanges = GitChangesController()
    let database: DatabaseController
    let agent: AgentController
    @ObservationIgnored let errors = ErrorCenter()
    @ObservationIgnored let docs = DocumentStore()
    @ObservationIgnored let trust: TrustStore
    @ObservationIgnored let recents: RecentProjectsStore
    @ObservationIgnored let session: WorkspaceSession
    @ObservationIgnored let projects: ProjectLibrary
    @ObservationIgnored let connections: ConnectionStore
    @ObservationIgnored let files: FileCommands
    @ObservationIgnored let bridge: AgentBridge
    /// Quién pregunta por la confianza de un proyecto nuevo. El valor por defecto
    /// **niega**: la interfaz inyecta el diálogo real con `forApp()`, así un entorno sin
    /// interfaz —pruebas, CI— nunca queda esperando un modal, y si alguien olvida
    /// inyectarlo el proyecto queda cerrado en vez de confiado.
    @ObservationIgnored var confirmTrust: @MainActor (TrustPrompt) -> TrustDecision = { _ in .cancel }
    @ObservationIgnored private var started = false

    // MARK: - Reenvíos
    // Las vistas le piden todo al controlador. Una línea cada uno, sin decisiones.

    var workspace: Workspace? { session.workspace }
    var workspaceURL: URL? { session.url }
    var isSwitchingWorkspace: Bool { session.isSwitching }
    var isReadOnly: Bool { session.isReadOnly }
    var runnableProjects: [CodeProject] { session.runnableProjects }
    var mountedProjects: [CodeProject] { session.mountedProjects }
    var documents: [EditorDocument] { docs.documents }
    var selectedDocument: EditorDocument? { gitChanges.tabVisible ? nil : docs.selected }
    var selectedProcessesVisible: Bool { processesVisible }
    func toggleProcessesPanel() {
        if processManager.isDetached { processManager.detach(self) }
        else {
            if processesVisible {
                processesVisible = false
                pixelProcessesVisible = false
                processManager.wasVisible = false
            } else { showProcessesPanel() }
        }
    }
    func showProcessesPanel() {
        if processManager.dockPosition == .bottom {
            if let url = workspaceURL { terminals.setVisible(false, for: url) }
            database.resultsVisible = false
            workflowVisible = false
            outputVisible = false
        }
        processesVisible = true
        pixelProcessesVisible = true
        processManager.wasVisible = true
    }
    func moveProcessesPanel(to position: ProcessManagerPresentation.DockPosition) {
        processManager.dockPosition = position
        showProcessesPanel()
    }
    var openingFiles: Set<URL> { docs.openingFiles }
    var recentProjects: [URL] { recents.urls }
    var selectedDocumentID: URL? {
        get { docs.selectedID }
        set { docs.selectedID = newValue
            if let document = docs.selected, document.language == "SQL" { sqlResultsDocumentID = document.id }
            if newValue != nil { gitChanges.tabVisible = false
                workflowVisible = false
                outputVisible = false } }
    }

    var selectedProject: CodeProject? {
        runnableProjects.first { $0.id == selectedProjectID } ?? runnableProjects.first
    }

    init(defaults: UserDefaults = .standard, settings: AppSettings? = nil, historyRoot: URL? = nil) {
        terminals = TerminalManager(defaults: defaults)
        processManager = ProcessManagerPresentation(defaults: defaults)
        database = DatabaseController(historyRoot: historyRoot)
        self.settings = settings ?? AppSettings(defaults: defaults)
        restoration = SessionRestoration(defaults: defaults)
        trust = TrustStore(defaults: defaults)
        agent = AgentController(defaults: defaults)
        recents = RecentProjectsStore(defaults: defaults)
        session = WorkspaceSession(trustStore: trust, errors: errors)
        sqlTimeouts = SQLTimeoutPreferences(defaults: defaults, settings: self.settings, session: session)
        projects = ProjectLibrary(session: session, runner: runner)
        projects.inheritedEnvironment = { [terminals] url in try terminals.sharedEnvironment(for: url) }
        connections = ConnectionStore(session: session, database: database, defaults: defaults)
        files = FileCommands(session: session, docs: docs, defaults: defaults)
        files.didSaveDraft = { [connections] document in
            connections.persistDraftSelection(document)
        }
        bridge = AgentBridge(session: session, agent: agent, docs: docs, files: files, runner: runner)
        files.requestNewFile = { [weak self] directory in
            guard let self, self.fileOperation == nil else { return }
            self.database.browserShowsDatabases = false
            self.sidebarVisible = true
            self.newFileDirectory = directory
            self.newFileRequest = UUID()
        }
        files.requestNewPixelArt = { [weak self] directory in
            guard let self, self.fileOperation == nil else { return }
            self.database.browserShowsDatabases = false
            self.sidebarVisible = true
            self.newPixelArtDirectory = directory
            self.newPixelArtRequest = UUID()
        }
        docs.didChange = { [weak self] in
            guard let self else { return }
            for document in self.documents { self.sqlTimeouts.bind(document) }
        }
        files.onOpen = { [weak self] in
            self?.gitChanges.tabVisible = false
            self?.workflowVisible = false
            self?.outputVisible = false
        }
        // Lo que el usuario ya venía usando se considera confiable, una sola vez.
        trust.migrateIfNeeded(recentProjects: recents.urls)
    }

    func start(arguments: [String] = ProcessInfo.processInfo.arguments) async {
        guard !started else { return }
        started = true
        QADiagnostics.activateIfRequested(arguments: arguments)
        QAProbe.action("app.start", ["restoring": QAField.bool(settings.restoreLastState)])
        if let index = arguments.firstIndex(of: "--workspace"), arguments.indices.contains(index + 1) {
            await openWorkspace(URL(fileURLWithPath: arguments[index + 1]))
            return
        }
        guard requestedWorkspaceURL == nil, requestedPixelArtURLs.isEmpty,
              settings.restoreLastState, let state = restoration.load() else { return }
        isRestoringSession = true
        await restoreSession(state)
        isRestoringSession = false
        if let requestedWorkspaceURL {
            await openWorkspace(requestedWorkspaceURL)
        }
    }

    /// Un archivo abierto desde Finder tiene prioridad sobre la sesión guardada.
    func requestWorkspace(_ url: URL) {
        if url.pathExtension.lowercased() == "pxa" {
            requestedPixelArtURLs.append(url)
            files.open(url)
            return
        }
        requestedWorkspaceURL = url
        guard !isRestoringSession else { return }
        Task { await openWorkspace(url) }
    }

    // MARK: - Abrir, crear y cerrar un proyecto

    func chooseWorkspace() {
        QAProbe.action("project.choose.request", ["switching": QAField.bool(session.isSwitching)])
        guard !session.isSwitching, let url = session.dialogs.chooseWorkspace() else { return }
        Task { await openWorkspace(url) }
    }

    func createWorkspace() {
        QAProbe.action("wizard.open.request", ["switching": QAField.bool(session.isSwitching)])
        guard !session.isSwitching else { return }
        showingProjectWizard = true
        QAProbe.state("state.wizard", ["presented": QAField.bool(true)])
    }

    /// Crea exclusivamente un archivo nuevo; nunca sobrescribe uno que apareció durante el asistente.
    func createWorkspace(from draft: ProjectDraft) async throws -> Bool {
        QAProbe.action("project.create.request", ["name": draft.trimmedName, "url": QAField.path(draft.url),
                                                  "projects": QAField.count(draft.projects.count),
                                                  "opening": QAField.bool(draft.openWhenCreated)])
        let project: Workspace
        do { project = try draft.workspace() }
        catch {
            QAProbe.failure("project.create.rejected", AppError.describe(error), ["name": draft.trimmedName])
            throw error
        }
        guard session.beginSwitch() else { return false }
        defer { session.endSwitch() }
        if draft.openWhenCreated { guard await prepareToLeave(preserveDocuments: workspaceURL != nil) else { return false } }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(project)
        try FileManager.default.createDirectory(at: draft.folder, withIntermediateDirectories: true)
        try data.write(to: draft.url, options: .withoutOverwriting)
        trust.markTrusted(draft.url)
        for item in project.projects where !item.command.isEmpty {
            trust.approve(command: item.command, project: item.id, workspaceURL: draft.url)
        }
        recents.remember(draft.url)
        QAProbe.action("project.create.ok", ["name": project.name, "url": QAField.path(draft.url),
                                             "opening": QAField.bool(draft.openWhenCreated)])
        if draft.openWhenCreated { install(project, at: draft.url, trust: .trusted) }
        return true
    }

    /// Se le pregunta por la confianza **antes** de molestar al usuario con lo que tiene
    /// abierto: si cancela ahí, su proyecto actual queda intacto.
    func openWorkspace(_ url: URL, prepared: Bool = false) async {
        QAProbe.action("project.open.request", ["url": QAField.path(url),
                                                "current": QAField.path(session.url),
                                                "switching": QAField.bool(session.isSwitching)])
        guard session.url != url.standardizedFileURL, session.beginSwitch() else {
            QAProbe.action("project.open.ignored", ["url": QAField.path(url)])
            return
        }
        defer { session.endSwitch() }
        do {
            let project = try await Task.detached(priority: .userInitiated) { try Workspace.read(from: url) }.value
            guard let decided = session.decideTrust(for: project, at: url, ask: confirmTrust) else {
                QAProbe.action("project.open.cancelled", ["url": QAField.path(url), "stage": "trust"])
                return
            }
            if !prepared {
                guard await prepareToLeave(preserveDocuments: workspaceURL != nil) else {
                    QAProbe.action("project.open.cancelled", ["url": QAField.path(url), "stage": "prepareToLeave"])
                    return
                }
            }
            install(project, at: url, trust: decided)
            if let parked = suspendedDocuments.removeValue(forKey: url.standardizedFileURL) {
                docs.resume(parked)
                if let state = workspaceStates[url.standardizedFileURL] {
                    await restoreTabs(state)
                    docs.selectedID = parked.selectedID
                }
            } else if let state = workspaceStates[url.standardizedFileURL] { await restoreTabs(state) }
            QAProbe.action("project.open.ok", ["url": QAField.path(url), "name": project.name,
                                               "readOnly": QAField.bool(decided == .untrusted)])
        } catch {
            QAProbe.failure("project.open.failed", AppError.describe(error), ["url": QAField.path(url)])
            errors.report(error)
        }
    }

    func requestCloseWorkspace(_ url: URL? = nil) {
        QAProbe.action("project.close.request", ["url": QAField.path(url ?? workspaceURL),
                                                 "switching": QAField.bool(isSwitchingWorkspace)])
        guard !isSwitchingWorkspace else { return }
        closingProjectURL = url ?? workspaceURL
        QAProbe.state("state.closeSheet", ["presented": QAField.bool(closingProjectURL != nil)])
    }

    func closeWorkspace(_ requestedURL: URL? = nil, prepared: Bool = false) async {
        guard !session.isSwitching, let closing = (requestedURL ?? workspaceURL)?.standardizedFileURL else { return }
        guard openWorkspaceURLs.contains(closing) else { return }
        if closing != workspaceURL {
            if !prepared, suspendedDocuments[closing] != nil {
                await openWorkspace(closing)
                guard workspaceURL == closing else { return }
                await closeWorkspace(closing)
                return
            }
            openWorkspaceURLs.removeAll { $0 == closing }
            workspaceStates.removeValue(forKey: closing)
            suspendedDocuments.removeValue(forKey: closing)
            openWorkspaceModels.removeValue(forKey: closing)
            return
        }
        if let next = openWorkspaceURLs.first(where: { $0 != closing }) {
            if !prepared { guard await prepareToLeave() else { return } }
            await openWorkspace(next, prepared: true)
            guard workspaceURL == next else { return }
            openWorkspaceURLs.removeAll { $0 == closing }
            workspaceStates.removeValue(forKey: closing)
            suspendedDocuments.removeValue(forKey: closing)
            openWorkspaceModels.removeValue(forKey: closing)
            return
        }
        guard session.workspace != nil, session.beginSwitch() else { return }
        defer { session.endSwitch() }
        if !prepared { guard await prepareToLeave() else { return } }
        openWorkspaceURLs.removeAll { $0 == closing }
        workspaceStates.removeValue(forKey: closing)
        openWorkspaceModels.removeValue(forKey: closing)
        docs.closeAll()
        gitChanges.reset()
        agent.clearConversation()
        selectedProjectID = nil
        commandProject = nil
        connections.install([])
        session.close()
        database.output.configure(project: nil)
        database.configureLists(project: nil)
        outputVisible = false
        database.resultsVisible = false
        sqlResultsDocumentID = nil
        restoration.clear()
        QAProbe.action("project.close.ok", ["url": QAField.path(closing)])
        QAProbe.state("state.workspace", ["url": "", "open": QAField.count(openWorkspaceURLs.count),
                                          "readOnly": QAField.bool(false)])
    }

    /// Recablea los servicios para el proyecto que se acaba de adoptar. El orden importa:
    /// las pestañas del proyecto anterior se cierran antes de que la sesión cambie, así
    /// ninguna queda apuntando a un archivo de un proyecto que ya no está abierto.
    private func install(_ project: Workspace, at url: URL, trust decided: TrustStore.Trust) {
        if let state = captureCurrentWorkspaceState() {
            workspaceStates[state.workspaceURL] = state
            openWorkspaceModels[state.workspaceURL] = workspace
        }
        gitChanges.reset()
        let normalized = url.standardizedFileURL
        if !openWorkspaceURLs.contains(normalized) { openWorkspaceURLs.append(normalized) }
        if let current = workspaceURL {
            suspendedDocuments[current] = docs.suspend()
        } else {
            docs.closeAll()
        }
        session.open(project, at: url, trust: decided)
        terminals.openProject(url)
        database.output.configure(project: url)
        database.configureLists(project: url)
        outputVisible = false
        database.resultsVisible = false
        sqlResultsDocumentID = nil
        openWorkspaceModels[normalized] = project
        connections.install(project.connections)
        bridge.reset(for: project, at: url, trust: decided)
        projects.warmUp(project.projects)
        if decided == .trusted {
            for parent in project.projects {
                for service in parent.configuredServices where service.configuration.startsAutomatically {
                    projects.startServices(parent, workspaceURL: url, serviceID: service.id, automatic: true)
                }
            }
        }
        selectedProjectID = runnableProjects.first?.id
        recents.remember(url)
        Log.workspace.info("""
            proyecto abierto · subproyectos \(project.projects.count, privacy: .public) \
            · conexiones \(project.connections.count, privacy: .public) \
            · \(decided == .trusted ? "confiable" : "solo lectura", privacy: .public)
            """)
        QAProbe.state("state.workspace", ["url": QAField.path(url), "name": project.name,
                                          "projects": QAField.count(project.projects.count),
                                          "connections": QAField.count(project.connections.count),
                                          "readOnly": QAField.bool(decided == .untrusted),
                                          "open": QAField.count(openWorkspaceURLs.count)])
    }

    func newQuery(connection: DatabaseConnection) {
        guard !isReadOnly, !isSwitchingWorkspace, workspace != nil else { return }
        do {
            let document = try docs.createDraft(name: "consulta.sql", text: "")
            connections.select(connection.id, for: document)
            workflowVisible = false
            let preferred = database.schema.preference(connection).defaultDatabase
            let target = preferred.isEmpty ? connection.database : preferred
            let state = database.state(connection.id)
            if !target.isEmpty, !state.busy, state.status != .connecting {
                if state.status == .connected { database.selectDatabase(target, connection: connection) }
                else { state.currentDatabase = target }
            }
        } catch { errors.report(error) }
    }

    func openTableQuery(_ table: SQLSchemaTable, connection: DatabaseConnection) {
        QAProbe.action("table.query.request", ["table": table.qualified, "connection": connection.name,
                                               "readOnly": QAField.bool(isReadOnly)])
        guard !isReadOnly else { return }
        Task {
            if let document = await files.createTableQuery(table) {
                QAProbe.action("table.query.ok", ["table": table.qualified, "connection": connection.name,
                                                  "sql": QAField.sql(document.text)])
                connections.select(connection.id, for: document)
                workflowVisible = false
                database.execute(document, connection: connection, databaseOverride: table.database)
            }
        }
    }

    func openTableDefinition(at position: Int, in document: EditorDocument) {
        guard let connection = connections.selected(for: document) else { return }
        let state = database.state(connection.id)
        guard let reference = SQLTableReference.at(position, in: document.text,
                                                   noBackslashEscapes: state.noBackslashEscapes) else { return }
        let target = reference.database ?? (state.currentDatabase.isEmpty ? connection.database : state.currentDatabase)
        guard !target.isEmpty else {
            errors.report(DatabaseFailure("Seleccioná una base de datos para abrir la definición de la tabla."))
            return
        }
        openTableDefinition(SQLSchemaTable(database: target, name: reference.name, kind: "BASE TABLE", engine: ""),
                            connection: connection)
    }

    func openTableDefinition(_ table: SQLSchemaTable, connection: DatabaseConnection) {
        let project = workspaceURL
        Task {
            do {
                let password = try CredentialStore.read(for: connection)
                let sql = try await database.client.createTable(table, config: connection, password: password)
                guard workspaceURL == project, connections.profiles.contains(where: { $0.id == connection.id }) else { return }
                _ = try docs.openTableDefinition(table, sql: sql)
                workflowVisible = false
            } catch {
                guard workspaceURL == project else { return }
                errors.report(error)
            }
        }
    }

    func openRelatedRecord(_ target: SQLRelatedTarget, connection: DatabaseConnection) {
        guard !isReadOnly, workspace != nil, !isSwitchingWorkspace else { return }
        guard connections.profiles.contains(where: {
            $0.id == connection.id && $0.configurationWithoutTint == connection.configurationWithoutTint
        }) else {
            errors.report(DatabaseFailure("La conexión del resultado cambió o se quitó. Volvé a ejecutar la consulta de origen."))
            return
        }
        do {
            let suggested = target.key.table + ".sql"
            let name = ExplorerFileSystem.validName(suggested) ? suggested : "registro.sql"
            let document = try docs.createDraft(name: name, text: target.query + "\n")
            connections.select(connection.id, for: document)
            workflowVisible = false
            outputVisible = false
            sqlResultsDocumentID = document.id
            database.execute(document, connection: connection, databaseOverride: target.key.database)
        } catch { errors.report(error) }
    }

    func renameFile(_ url: URL) {
        guard fileOperation == nil else { return }
        if let destination = files.rename(url) { connections.relocateScript(from: url, to: destination) }
    }

    func moveOpenWorkspace(_ url: URL, to target: URL) {
        QAProbe.action("project.rail.move.request", ["project": QAField.path(url), "before": QAField.path(target)])
        guard !isSwitchingWorkspace, let source = openWorkspaceURLs.firstIndex(of: url),
              let destination = openWorkspaceURLs.firstIndex(of: target), source != destination else {
            QAProbe.action("project.rail.move.ignored", ["switching": QAField.bool(isSwitchingWorkspace)])
            return
        }
        openWorkspaceURLs.remove(at: source)
        openWorkspaceURLs.insert(url, at: destination)
        QAProbe.state("state.rail", ["order": openWorkspaceURLs.map { $0.deletingPathExtension().lastPathComponent }
                .joined(separator: ","), "open": QAField.count(openWorkspaceURLs.count)])
    }

    func adoptRelocatedWorkspace(_ updated: Workspace, from old: URL, to url: URL) {
        sqlTimeouts.relocateProject(from: old, to: url)
        connections.relocateProject(from: old, to: url)
        openWorkspaceURLs = openWorkspaceURLs.map { $0 == old ? url : $0 }
        openWorkspaceModels.removeValue(forKey: old)
        openWorkspaceModels[url] = updated
        workspaceStates.removeValue(forKey: old)
        if let parked = suspendedDocuments.removeValue(forKey: old) { suspendedDocuments[url] = parked }
        session.open(updated, at: url, trust: .trusted)
        for document in documents { sqlTimeouts.bind(document) }
        connections.install(updated.connections)
        bridge.reset(for: updated, at: url, trust: .trusted)
        projects.warmUp(updated.projects)
        workspaceStates[url] = captureCurrentWorkspaceState()
        recents.forget(old)
        recents.remember(url)
    }

    /// El orden en que se le pregunta al usuario antes de dejar lo que está abierto:
    /// Codex, los archivos sin guardar, los procesos, la base. Cualquiera cancela todo.
    func prepareToLeave(preserveDocuments: Bool = false) async -> Bool {
        QAProbe.action("project.prepareToLeave.begin", ["agent": QAField.bool(agent.isRunning),
                                                        "processes": QAField.bool(runner.hasActiveProcesses),
                                                        "dirty": QAField.count(docs.dirty.count)])
        guard fileOperation == nil else { return false }
        if agent.isRunning {
            guard session.dialogs.confirmStopAgent() else { return false }
            agent.shutdown()
        }
        if !preserveDocuments { guard await files.resolveDirty() else { return false } }
        if workflows.isRunning {
            guard session.dialogs.confirmStopProcesses() else { return false }
            workflows.stop()
        }
        guard await database.prepareToLeave(closeIdleConnections: false) else {
            QAProbe.action("project.prepareToLeave.cancelled", ["stage": "database"])
            return false
        }
        agent.shutdown()
        QAProbe.action("project.prepareToLeave.ok")
        return true
    }

    /// Al salir, pregunta por cada archivo con cambios antes de intentar guardarlo.
    /// Elegir «No guardar» permite cerrar sin abrir un selector de ubicación.
    func prepareToQuit(keepingManagedProcesses: Bool = false) async -> Bool {
        guard fileOperation == nil else { return false }
        guard await terminals.prepareToQuit() else { return false }
        for document in documents {
            guard document.sqlExecution.drafts.values.allSatisfy({ !$0.sending && $0.confirmDiscard() }) else { return false }
        }
        let running = (!keepingManagedProcesses && runner.hasActiveProcesses) || workflows.isRunning || agent.isRunning ||
            database.hasActiveWork ||
            documents.contains { $0.sqlExecution.isRunning }
        if running && !session.dialogs.confirmStopProcesses() { return false }
        guard await files.resolveDirty() else { return false }
        let initialWorkspace = workspaceURL
        for url in openWorkspaceURLs where url != workspaceURL {
            await openWorkspace(url)
            guard workspaceURL == url, await files.resolveDirty() else { return false }
        }
        if let initialWorkspace, workspaceURL != initialWorkspace { await openWorkspace(initialWorkspace) }
        workflows.stop()
        agent.shutdown()
        return await database.prepareToLeave(confirmActivity: false)
    }

    // MARK: - Lo que necesita más de un colaborador a la vez

    /// Mostrar el panel de procesos es de la ventana; decidir si el comando puede
    /// ejecutarse es de `ProjectLibrary`.
    func startAll() {
        projects.startAll()
        processManager.show(self)
    }

    func toggleRun(_ project: CodeProject) {
        selectedProjectID = project.id
        projects.toggleRun(project)
        processManager.show(self)
    }

    /// Detener desde el menú: corta todos los procesos y deja el panel a la vista, que es
    /// donde se ve el resultado.
    func stopAll() {
        QAProbe.action("process.stopAll.request", ["active": QAField.bool(runner.hasActiveProcesses)])
        runner.stopAll()
        processManager.show(self)
    }

    func executeSQL() {
        if SQLGridTable.reviewFocusedGrid() { return }
        guard let document = selectedDocument, document.language == "SQL", !document.isTableDefinition,
              let connection = connections.selected(for: document), !isReadOnly else {
            QAProbe.action("sql.execute.unavailable", ["language": selectedDocument?.language ?? "",
                                                       "readOnly": QAField.bool(isReadOnly),
                                                       "connection": QAField.bool(selectedDocument
                                                           .flatMap { connections.selected(for: $0) } != nil)])
            return
        }
        sqlResultsDocumentID = document.id
        outputVisible = false
        workflowVisible = false
        database.execute(document, connection: connection)
    }

    func executeSQLFile() {
        guard let document = selectedDocument, document.language == "SQL", !document.isTableDefinition,
              let connection = connections.selected(for: document), !isReadOnly else { return }
        sqlResultsDocumentID = document.id
        outputVisible = false
        workflowVisible = false
        let text = document.text
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            document.sqlExecution.error = "El archivo SQL está vacío."
            database.resultsVisible = true
            return
        }
        database.execute(document, connection: connection, queryOverride: text, replaceUnpinnedResults: true)
    }

    /// Cerrar una pestaña es de `FileCommands`; cancelar la consulta que esa pestaña
    /// todavía está corriendo es de la base.
    func closeDocument(_ document: EditorDocument) {
        Task { await files.close(document, cancelQuery: database.cancel) }
    }

    func navigatePixelHistory(redo: Bool) {
        guard let document = selectedDocument, document.pixelArt != nil,
              !isReadOnly, document.pixelArt?.isReadOnly != true else { return }
        do { try document.navigatePixelHistory(redo: redo) }
        catch { errors.report(error) }
    }

    func closeTabs(_ targets: [EditorDocument], closeWorkflow: Bool = false) {
        Task {
            for document in targets {
                guard await files.close(document, cancelQuery: database.cancel) else { return }
            }
            if closeWorkflow {
                workflowVisible = false
                workflowTabOpen = false
            }
        }
    }

    func moveTab(_ source: URL, before target: URL) {
        docs.moveTab(source, before: target)
    }
}
