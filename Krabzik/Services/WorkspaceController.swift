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
/// Lo que no se puede perder: **abrir un proyecto no ejecuta nada**. Un `.krabzik` que no
/// se abrió antes entra en solo lectura, y de ahí dependen los gates de la sesión (S1).
///
/// Confinado al main actor. Ver docs/specs/C5-dividir-workspacecontroller.md.
@MainActor @Observable
final class WorkspaceController {
    let settings: AppSettings
    @ObservationIgnored let restoration: SessionRestoration
    private(set) var isRestoringSession = false
    @ObservationIgnored private(set) var requestedWorkspaceURL: URL?
    var selectedProjectID: UUID?
    var sidebarVisible = true
    var processesVisible = true
    var commandProject: CodeProject?
    let runner = ProcessRunner()
    let database = DatabaseController()
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
    var selectedDocument: EditorDocument? { docs.selected }
    var openingFiles: Set<URL> { docs.openingFiles }
    var recentProjects: [URL] { recents.urls }
    var selectedDocumentID: URL? {
        get { docs.selectedID }
        set { docs.selectedID = newValue }
    }

    var selectedProject: CodeProject? {
        runnableProjects.first { $0.id == selectedProjectID } ?? runnableProjects.first
    }

    init(defaults: UserDefaults = .standard, settings: AppSettings? = nil) {
        self.settings = settings ?? AppSettings(defaults: defaults)
        restoration = SessionRestoration(defaults: defaults)
        trust = TrustStore(defaults: defaults)
        agent = AgentController(defaults: defaults)
        recents = RecentProjectsStore(defaults: defaults)
        session = WorkspaceSession(trustStore: trust, errors: errors)
        projects = ProjectLibrary(session: session, runner: runner)
        connections = ConnectionStore(session: session, database: database)
        files = FileCommands(session: session, docs: docs)
        bridge = AgentBridge(session: session, agent: agent, docs: docs, files: files)
        // Lo que el usuario ya venía usando se considera confiable, una sola vez.
        trust.migrateIfNeeded(recentProjects: recents.urls)
    }

    func start(arguments: [String] = ProcessInfo.processInfo.arguments) async {
        guard !started else { return }
        started = true
        if let index = arguments.firstIndex(of: "--workspace"), arguments.indices.contains(index + 1) {
            await openWorkspace(URL(fileURLWithPath: arguments[index + 1]))
            return
        }
        guard requestedWorkspaceURL == nil, settings.restoreLastState, let state = restoration.load() else { return }
        isRestoringSession = true
        await restoreSession(state)
        isRestoringSession = false
        if let requestedWorkspaceURL {
            await openWorkspace(requestedWorkspaceURL)
        }
    }

    /// Un archivo abierto desde Finder tiene prioridad sobre la sesión guardada.
    func requestWorkspace(_ url: URL) {
        requestedWorkspaceURL = url
        guard !isRestoringSession else { return }
        Task { await openWorkspace(url) }
    }

    // MARK: - Abrir, crear y cerrar un proyecto

    func chooseWorkspace() {
        guard !session.isSwitching, let url = session.dialogs.chooseWorkspace() else { return }
        Task { await openWorkspace(url) }
    }

    func createWorkspace() {
        guard !session.isSwitching, let url = session.dialogs.createWorkspace() else { return }
        Task {
            guard session.beginSwitch() else { return }
            defer { session.endSwitch() }
            guard await prepareToLeave() else { return }
            do {
                let name = url.deletingPathExtension().lastPathComponent
                install(try session.create(named: name, at: url), at: url, trust: .trusted)
            } catch { errors.report(error) }
        }
    }

    /// Se le pregunta por la confianza **antes** de molestar al usuario con lo que tiene
    /// abierto: si cancela ahí, su proyecto actual queda intacto.
    func openWorkspace(_ url: URL) async {
        guard session.url != url.standardizedFileURL, session.beginSwitch() else { return }
        defer { session.endSwitch() }
        do {
            let project = try await Task.detached(priority: .userInitiated) { try Workspace.read(from: url) }.value
            guard let decided = session.decideTrust(for: project, at: url, ask: confirmTrust) else { return }
            guard await prepareToLeave() else { return }
            install(project, at: url, trust: decided)
        } catch { errors.report(error) }
    }

    func closeWorkspace() async {
        guard session.workspace != nil, session.beginSwitch() else { return }
        defer { session.endSwitch() }
        guard await prepareToLeave() else { return }
        docs.closeAll()
        selectedProjectID = nil
        commandProject = nil
        connections.install([])
        session.close()
        restoration.clear()
    }

    /// Recablea los servicios para el proyecto que se acaba de adoptar. El orden importa:
    /// las pestañas del proyecto anterior se cierran antes de que la sesión cambie, así
    /// ninguna queda apuntando a un archivo de un proyecto que ya no está abierto.
    private func install(_ project: Workspace, at url: URL, trust decided: TrustStore.Trust) {
        docs.closeAll()
        session.open(project, at: url, trust: decided)
        connections.install(project.connections)
        bridge.reset(for: project, at: url, trust: decided)
        projects.warmUp(project.projects)
        selectedProjectID = runnableProjects.first?.id
        recents.remember(url)
        Log.workspace.info("""
            proyecto abierto · subproyectos \(project.projects.count, privacy: .public) \
            · conexiones \(project.connections.count, privacy: .public) \
            · \(decided == .trusted ? "confiable" : "solo lectura", privacy: .public)
            """)
    }

    /// El orden en que se le pregunta al usuario antes de dejar lo que está abierto:
    /// Codex, los archivos sin guardar, los procesos, la base. Cualquiera cancela todo.
    func prepareToLeave() async -> Bool {
        if agent.isRunning {
            guard session.dialogs.confirmStopAgent() else { return false }
            agent.shutdown()
        }
        guard await files.resolveDirty() else { return false }
        if runner.hasActiveProcesses {
            guard session.dialogs.confirmStopProcesses() else { return false }
            runner.stopAll()
        }
        guard await database.prepareToLeave() else { return false }
        agent.shutdown()
        return true
    }

    // MARK: - Lo que necesita más de un colaborador a la vez

    /// Mostrar el panel de procesos es de la ventana; decidir si el comando puede
    /// ejecutarse es de `ProjectLibrary`.
    func startAll() {
        projects.startAll()
        processesVisible = true
    }

    func toggleRun(_ project: CodeProject) {
        selectedProjectID = project.id
        projects.toggleRun(project)
        processesVisible = true
    }

    func executeSQL() {
        guard let document = selectedDocument, document.language == "SQL",
              let connection = connections.selected else { return }
        database.execute(document, connection: connection)
    }

    /// Cerrar una pestaña es de `FileCommands`; cancelar la consulta que esa pestaña
    /// todavía está corriendo es de la base.
    func closeDocument(_ document: EditorDocument) {
        Task { await files.close(document, cancelQuery: database.cancel) }
    }
}
