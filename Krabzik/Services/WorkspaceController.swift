import AppKit
import Observation
import UniformTypeIdentifiers

extension UTType {
    static let krabzikProject = UTType(exportedAs: "com.krabzik.project", conformingTo: .json)
}

@MainActor @Observable
final class WorkspaceController {
    var workspace: Workspace?
    var workspaceURL: URL?
    var documents: [EditorDocument] = []
    var selectedDocumentID: URL?
    var selectedProjectID: UUID?
    var recentProjects: [URL] = []
    private(set) var isSwitchingWorkspace = false
    var sidebarVisible = true
    var processesVisible = true
    var errorMessage: String?
    var commandProject: CodeProject?
    var treeRevision = 0
    var openingFiles: Set<URL> = []
    let runner = ProcessRunner()
    let database = DatabaseController()
    let agent = AgentController()
    @ObservationIgnored private var started = false
    @ObservationIgnored private var pendingOpen: Set<URL> = []
    @ObservationIgnored private let defaults: UserDefaults

    var selectedDocument: EditorDocument? { documents.first { $0.id == selectedDocumentID } }
    var runnableProjects: [CodeProject] { workspace?.projects.filter { !$0.command.isEmpty } ?? [] }
    var selectedProject: CodeProject? {
        runnableProjects.first { $0.id == selectedProjectID } ?? runnableProjects.first
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var seen: Set<URL> = []
        recentProjects = Array((defaults.stringArray(forKey: "recentProjects") ?? [])
            .map { URL(fileURLWithPath: $0).standardizedFileURL }
            .filter { seen.insert($0).inserted }.prefix(10))
        agent.onFilesChanged = { [weak self] scope in self?.refreshAgentFiles(scope) }
    }

    func start(arguments: [String] = ProcessInfo.processInfo.arguments) async {
        guard !started else { return }
        started = true
        if let index = arguments.firstIndex(of: "--workspace"), arguments.indices.contains(index + 1) {
            await openWorkspace(URL(fileURLWithPath: arguments[index + 1]))
        }
    }

    func chooseWorkspace() {
        guard !isSwitchingWorkspace else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.krabzikProject, .json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = ""
        panel.prompt = "Abrir"
        if panel.runModal() == .OK, let url = panel.url { Task { await openWorkspace(url) } }
    }

    func createWorkspace() {
        guard !isSwitchingWorkspace else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.krabzikProject]
        panel.nameFieldStringValue = "Mi proyecto.krabzik"
        panel.canCreateDirectories = true
        panel.prompt = "Crear"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            guard !isSwitchingWorkspace else { return }
            isSwitchingWorkspace = true
            defer { isSwitchingWorkspace = false }
            guard await prepareToLeave() else { return }
            do {
                let project = Workspace(name: url.deletingPathExtension().lastPathComponent)
                try project.write(to: url)
                install(project, at: url)
            } catch { show(error) }
        }
    }

    func openWorkspace(_ url: URL) async {
        guard !isSwitchingWorkspace, workspaceURL != url.standardizedFileURL else { return }
        isSwitchingWorkspace = true
        defer { isSwitchingWorkspace = false }
        do {
            let project = try await Task.detached(priority: .userInitiated) { try Workspace.read(from: url) }.value
            guard await prepareToLeave() else { return }
            install(project, at: url)
        } catch { show(error) }
    }

    func closeWorkspace() async {
        guard !isSwitchingWorkspace, workspace != nil else { return }
        isSwitchingWorkspace = true
        defer { isSwitchingWorkspace = false }
        guard await prepareToLeave() else { return }
        releaseEditors()
        documents.removeAll()
        selectedDocumentID = nil
        selectedProjectID = nil
        workspace = nil
        workspaceURL = nil
        commandProject = nil
        database.editingConnection = nil
        database.install([])
        treeRevision += 1
    }

    func removeRecentProject(_ url: URL) {
        recentProjects.removeAll { $0 == url.standardizedFileURL }
        defaults.set(recentProjects.map(\.path), forKey: "recentProjects")
    }

    private func install(_ project: Workspace, at url: URL) {
        releaseEditors()
        documents.removeAll()
        selectedDocumentID = nil
        workspace = project
        workspaceURL = url.standardizedFileURL
        database.install(project.connections)
        agent.clearConversation()
        agent.selectedProjectID = nil
        agent.draft = ""
        for item in project.projects { _ = runner.state(for: item.id) }
        selectedProjectID = runnableProjects.first?.id
        treeRevision += 1
        recentProjects.removeAll { $0 == url.standardizedFileURL }
        recentProjects.insert(url.standardizedFileURL, at: 0)
        recentProjects = Array(recentProjects.prefix(10))
        defaults.set(recentProjects.map(\.path), forKey: "recentProjects")
    }

    func addFolders() {
        guard let workspaceURL else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Agregar"
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
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
                }
            }
            persist(updated)
        }
    }

    func updateProject(_ updated: CodeProject) {
        guard var project = workspace, let index = project.projects.firstIndex(where: { $0.id == updated.id }) else { return }
        project.projects[index] = updated
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
        } catch { show(error); return false }
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
        catch { try? CredentialStore.save(oldPassword, for: connection); throw error }
        if let previous, previous.host.lowercased() != connection.host.lowercased() || previous.port != connection.port || previous.username != connection.username || previous.tls != connection.tls {
            try? CredentialStore.remove(for: previous)
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

    func scriptURL(_ path: String) -> URL {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        return (workspaceURL?.deletingLastPathComponent() ?? FileManager.default.temporaryDirectory).appendingPathComponent(path)
    }

    func importScripts() {
        guard workspace != nil else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "sql") ?? .plainText]
        panel.allowsMultipleSelection = true
        panel.prompt = "Abrir"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { rememberScript(url); openFile(url) }
    }

    private func rememberScript(_ url: URL) {
        guard url.pathExtension.lowercased() == "sql", var updated = workspace, let workspaceURL else { return }
        if updated.projects.contains(where: { url.path.hasPrefix($0.directory(relativeTo: workspaceURL).path + "/") }) { return }
        let base = workspaceURL.deletingLastPathComponent().path + "/"
        let path = url.path.hasPrefix(base) ? String(url.path.dropFirst(base.count)) : url.path
        guard !updated.scripts.contains(path) else { return }
        updated.scripts.append(path)
        persist(updated)
    }

    func openFile(_ url: URL) {
        let url = url.standardizedFileURL
        if documents.contains(where: { $0.id == url }) { selectedDocumentID = url; return }
        guard !pendingOpen.contains(url) else { return }
        pendingOpen.insert(url)
        openingFiles.insert(url)
        let currentWorkspace = workspaceURL
        Task {
            defer { pendingOpen.remove(url); openingFiles.remove(url) }
            do {
                let data = try await Task.detached(priority: .userInitiated) { try DocumentIO.read(url) }.value
                guard workspaceURL == currentWorkspace else { return }
                let document = try EditorDocument(url: url, data: data)
                documents.append(document)
                selectedDocumentID = document.id
            } catch { show(error) }
        }
    }

    func createFile(in directory: URL? = nil) {
        guard workspace != nil else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "nuevo.sql"
        panel.directoryURL = directory ?? selectedDocument?.url.deletingLastPathComponent() ?? workspaceURL?.deletingLastPathComponent()
        panel.canCreateDirectories = true
        panel.prompt = "Crear"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            // The save panel supplies the explicit overwrite choice when a path exists.
            try Data().write(to: url, options: .atomic)
            rememberScript(url)
            treeRevision += 1
            openFile(url)
        } catch { show(error) }
    }

    @discardableResult func save(_ document: EditorDocument) async -> Bool {
        guard !document.isSaving else { return false }
        document.isSaving = true
        defer { document.isSaving = false }
        let data = Data(document.text.utf8), expected = document.originalData, url = document.url
        do {
            try await Task.detached(priority: .userInitiated) { try DocumentIO.save(data, to: url, expected: expected) }.value
            document.originalData = data
            document.isDirty = Data(document.text.utf8) != data
            return true
        } catch { show(error); return false }
    }

    func saveCopy() {
        guard let document = selectedDocument else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = document.url.deletingPathExtension().lastPathComponent + "-copia." + document.url.pathExtension
        panel.directoryURL = document.url.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try Data(document.text.utf8).write(to: url, options: .atomic); treeRevision += 1 }
        catch { show(error) }
    }

    func closeDocument(_ document: EditorDocument) {
        Task {
            if document.sqlExecution.isRunning {
                let alert = NSAlert()
                alert.messageText = "¿Cancelar la consulta y cerrar el archivo?"
                alert.addButton(withTitle: "Cancelar consulta")
                alert.addButton(withTitle: "Volver")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                database.cancel(document.sqlExecution)
            }
            guard await confirmSave(document) else { return }
            let index = documents.firstIndex { $0.id == document.id } ?? 0
            document.releaseEditor()
            documents.removeAll { $0.id == document.id }
            if selectedDocumentID == document.id {
                selectedDocumentID = documents.isEmpty ? nil : documents[min(index, documents.count - 1)].id
            }
        }
    }

    private func confirmSave(_ document: EditorDocument) async -> Bool {
        guard document.isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "¿Guardar \(document.url.lastPathComponent)?"
        alert.informativeText = "Hay cambios sin guardar."
        alert.addButton(withTitle: "Guardar")
        alert.addButton(withTitle: "Cancelar")
        alert.addButton(withTitle: "No guardar")
        let result = alert.runModal()
        if result == .alertFirstButtonReturn { return await save(document) }
        return result == .alertThirdButtonReturn
    }

    func prepareToLeave() async -> Bool {
        if agent.isRunning {
            let alert = NSAlert()
            alert.messageText = "¿Detener Codex?"
            alert.informativeText = "Los cambios ya realizados se conservarán."
            alert.addButton(withTitle: "Detener y continuar")
            alert.addButton(withTitle: "Cancelar")
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
            agent.shutdown()
        }
        for document in documents where document.isDirty {
            if !(await confirmSave(document)) { return false }
        }
        if runner.hasActiveProcesses {
            let alert = NSAlert()
            alert.messageText = "¿Detener los procesos?"
            alert.informativeText = "Los procesos de este proyecto siguen en ejecución."
            alert.addButton(withTitle: "Detener")
            alert.addButton(withTitle: "Cancelar")
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
            runner.stopAll()
        }
        guard await database.prepareToLeave() else { return false }
        agent.shutdown()
        return true
    }

    func sendToAgent() {
        guard let workspace, let workspaceURL, !agent.isRunning, !isSwitchingWorkspace else { return }
        let prompt = agent.draft
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Task {
            do {
                let scope = try AgentScope.make(workspace: workspace, url: workspaceURL, projectID: agent.selectedProjectID)
                let dirty = documents.filter { $0.isDirty && scope.contains($0.url) }
                if !dirty.isEmpty {
                    let alert = NSAlert()
                    alert.messageText = "¿Guardar antes de enviar a Codex?"
                    alert.informativeText = dirty.map { $0.url.lastPathComponent }.joined(separator: ", ")
                    alert.addButton(withTitle: "Guardar y enviar"); alert.addButton(withTitle: "Cancelar")
                    guard alert.runModal() == .alertFirstButtonReturn else { return }
                    for document in dirty { guard await save(document) else { return } }
                }
                guard self.workspaceURL == workspaceURL, !isSwitchingWorkspace else { return }
                agent.send(prompt, scope: scope)
            } catch { agent.error = error.localizedDescription }
        }
    }

    private func refreshAgentFiles(_ scope: AgentScope) {
        treeRevision += 1
        let currentWorkspace = workspaceURL
        let candidates = documents.filter { scope.contains($0.url) }
        Task {
            for document in candidates {
                let url = document.url
                let data = try? await Task.detached(priority: .utility) { try DocumentIO.read(url) }.value
                guard workspaceURL == currentWorkspace, documents.contains(where: { $0 === document }) else { continue }
                if let data { document.acceptExternalData(data) }
                else { document.hasExternalChange = true }
            }
        }
    }

    func reloadDocument(_ document: EditorDocument) {
        if document.isDirty {
            let alert = NSAlert()
            alert.messageText = "¿Recargar \(document.url.lastPathComponent)?"
            alert.informativeText = "Se descartarán tus cambios sin guardar."
            alert.addButton(withTitle: "Recargar"); alert.addButton(withTitle: "Cancelar")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        do { document.acceptExternalData(try DocumentIO.read(document.url), discardEdits: true) }
        catch { show(error) }
    }

    func openAgentFile(_ path: String) {
        guard let workspace, let workspaceURL,
              let scope = try? AgentScope.make(workspace: workspace, url: workspaceURL, projectID: agent.selectedProjectID) else { return }
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : scope.cwd.appendingPathComponent(path)
        guard scope.contains(url) else { agent.error = "El archivo no pertenece a los subproyectos seleccionados."; return }
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
        for project in runnableProjects { runner.start(project, workspaceURL: workspaceURL) }
        processesVisible = true
    }

    func toggleRun(_ project: CodeProject) {
        guard let workspaceURL else { return }
        selectedProjectID = project.id
        let state = runner.state(for: project.id)
        if state.status.active { runner.stop(project.id) }
        else { runner.start(project, workspaceURL: workspaceURL) }
        processesVisible = true
    }

    /// Suelta las vistas nativas antes de descartar los documentos: el `deinit` de
    /// `EditorSurface` no puede hacerlo bajo las reglas de concurrencia de Swift 6.
    private func releaseEditors() {
        for document in documents { document.releaseEditor() }
    }

    func show(_ error: Error) { errorMessage = error.localizedDescription }
}
