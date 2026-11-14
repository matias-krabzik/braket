import Foundation

/// Lo que la ventana le da a Codex y lo que le acepta de vuelta.
///
/// Las dos direcciones van juntas porque las dos dependen del mismo `AgentScope`, que es
/// donde se aplica el modelo de confianza de S1: en solo lectura el scope no incluye
/// carpetas externas, y un archivo que Codex nombre fuera del scope no se abre. Enviar y
/// recibir con dos ideas distintas de qué carpetas valen sería exactamente el agujero.
///
/// Confinado al main actor. Ver docs/specs/C5-dividir-workspacecontroller.md.
@MainActor
final class AgentBridge {
    private let session: WorkspaceSession
    private let agent: AgentController
    private let docs: DocumentStore
    private let files: FileCommands
    private let runner: ProcessRunner

    init(session: WorkspaceSession, agent: AgentController, docs: DocumentStore, files: FileCommands, runner: ProcessRunner) {
        self.session = session
        self.agent = agent
        self.docs = docs
        self.files = files
        self.runner = runner
        agent.onFilesChanged = { [weak self] scope in self?.refresh(scope) }
        agent.contextProvider = { [weak self] scope in self?.context(scope) ?? "Proyecto cerrado." }
        agent.scopeProvider = { [weak self] in
            guard let self, self.session.trust == .trusted else { throw AgentFailure("Confiá en el proyecto para abrir la sesión.") }
            return try self.makeScope()
        }
    }

    /// Deja el agente listo para otro proyecto: sin conversación, sin subproyecto elegido
    /// y sin el borrador del anterior.
    ///
    /// `excludedRoots` son las carpetas del proyecto, para que un repositorio no pueda
    /// aportar su propio ejecutable de Codex. El panel se esconde si el proyecto entró en
    /// solo lectura: ahí no hay nada que Codex pueda hacer.
    func reset(for project: Workspace, at url: URL, trust: TrustStore.Trust) {
        agent.configureSessions(workspace: url)
        agent.selectedProjectID = nil
        agent.excludedRoots = project.projects.map { $0.directory(relativeTo: url) }
        agent.visible = agent.visible && trust == .trusted
        agent.draft = ""
    }

    /// Envía el borrador, guardando antes los archivos del scope que tengan cambios: lo
    /// que Codex lee tiene que ser lo que el usuario ve.
    func send() {
        guard session.trust == .trusted else {
            agent.error = "El proyecto está en solo lectura. Confiá en él para trabajar con Codex."
            return
        }
        guard let workspaceURL = session.url, !agent.isBusy else { return }
        let sessionID = agent.selectedSessionID
        let prompt = agent.draft
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Task {
            do {
                let scope = try makeScope()
                let dirty = docs.dirty.filter { scope.contains($0.url) }
                if !dirty.isEmpty {
                    guard session.dialogs.confirmSaveBeforeSending(dirty.map { $0.url.lastPathComponent }) else { return }
                    for document in dirty where !(await files.save(document)) { return }
                }
                guard session.url == workspaceURL, agent.selectedSessionID == sessionID else { return }
                let deliveryMode = agent.deliveryMode
                agent.deliveryMode = false
                agent.send(prompt, scope: scope,
                           context: context(scope) + (deliveryMode ? "\nModo Entrega habilitado por el usuario para este turno." : ""),
                           deliveryMode: deliveryMode)
            } catch { agent.error = error.localizedDescription }
        }
    }

    private func context(_ scope: AgentScope) -> String {
        guard session.trust == .trusted, let workspace = session.workspace, let url = session.url else { return "Proyecto cerrado." }
        return AgentContext.capture(scope: scope, docs: docs, workspace: workspace, url: url, runner: runner)
    }

    /// Abre un archivo que Codex nombró. Una ruta de fuera del scope se rechaza con un
    /// mensaje en vez de abrirse.
    func openFile(_ path: String) {
        guard let scope = try? makeScope() else { return }
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : scope.cwd.appendingPathComponent(path)
        guard scope.contains(url) else {
            agent.error = "El archivo no pertenece a los subproyectos seleccionados."
            return
        }
        files.open(url)
    }

    /// La ruta como la ve el usuario: `subproyecto/archivo` en vez de la ruta absoluta.
    func label(_ path: String) -> String {
        guard let workspaceURL = session.url else { return path }
        for project in session.workspace?.projects ?? [] {
            let prefix = project.directory(relativeTo: workspaceURL).resolvingSymlinksInPath().path + "/"
            if path.hasPrefix(prefix) { return project.name + "/" + path.dropFirst(prefix.count) }
        }
        return path
    }

    /// Codex tocó archivos: el árbol puede haber quedado viejo y los documentos abiertos
    /// del scope se releen.
    private func refresh(_ scope: AgentScope) {
        session.touch()
        let currentWorkspace = session.url
        Task {
            await docs.refresh(matching: { scope.contains($0) },
                               stillValid: { self.session.url == currentWorkspace })
        }
    }

    private func makeScope() throws -> AgentScope {
        guard let workspace = session.workspace, let url = session.url else {
            throw AgentFailure("Abrí un proyecto para trabajar con Codex.")
        }
        return try AgentScope.make(workspace: workspace, url: url,
                                   projectID: agent.selectedProjectID,
                                   allowExternal: session.trust == .trusted)
    }
}
