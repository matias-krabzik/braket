import Foundation

/// Los subproyectos del proyecto abierto: agregarlos, editarlos, quitarlos, y decidir si
/// su comando puede ejecutarse.
///
/// Las dos mitades van juntas porque comparten el mismo modelo de aprobación: un comando
/// que el usuario eligió en el panel o escribió en la hoja queda aprobado al guardarlo
/// —`TrustStore.approve`—, y `allowedToRun` consulta esa misma aprobación, que se guarda
/// por hash del comando. Separarlas dejaría la aprobación escrita en un tipo y leída en
/// otro, que es justo donde se cuela un comando que corre sin que nadie lo haya visto.
///
/// La puerta vive acá y no en `ProcessRunner` porque es acá donde se conoce el proyecto y
/// la confianza de la sesión. El runner solo lanza procesos.
///
/// Confinado al main actor. Ver docs/specs/C5-dividir-workspacecontroller.md.
@MainActor
final class ProjectLibrary {
    /// Quién pregunta por un comando sin aprobar. El valor por defecto **niega**: la
    /// interfaz inyecta el diálogo real con `WorkspaceController.forApp()`, así un entorno
    /// sin interfaz —pruebas, CI— nunca queda esperando un modal y, si alguien olvida
    /// inyectarlo, el comando no se ejecuta en vez de ejecutarse sin preguntar.
    var confirmCommand: @MainActor (CommandPrompt) -> CommandDecision = { _ in .cancel }
    private let session: WorkspaceSession
    private let runner: ProcessRunner

    init(session: WorkspaceSession, runner: ProcessRunner) {
        self.session = session
        self.runner = runner
    }

    /// Agrega las carpetas que el usuario elija, detectando el tipo y el comando de cada
    /// una. Una carpeta que ya está no se repite.
    func addFolders() {
        guard let workspaceURL = session.url else { return }
        let urls = session.dialogs.chooseFolders()
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
            guard session.url == workspaceURL, var updated = session.workspace else { return }
            for project in detected {
                let directory = project.directory(relativeTo: workspaceURL)
                if !updated.projects.contains(where: { $0.directory(relativeTo: workspaceURL) == directory }) {
                    updated.projects.append(project)
                    // La carpeta la eligió el usuario en el panel: su comando detectado
                    // queda aprobado, para no pedirle confirmación de algo que pidió.
                    if !project.command.isEmpty {
                        session.trustStore.approve(command: project.commandApproval, project: project.id,
                                                   workspaceURL: workspaceURL)
                    }
                }
            }
            guard session.write(updated) else { return }
            warmUp(updated.projects)
        }
    }

    func update(_ updated: CodeProject) {
        guard var project = session.workspace,
              let index = project.projects.firstIndex(where: { $0.id == updated.id }) else { return }
        project.projects[index] = updated
        // Lo que el usuario acaba de escribir no hace falta volver a confirmárselo.
        if let workspaceURL = session.url, !updated.command.isEmpty {
            session.trustStore.approve(command: updated.commandApproval, project: updated.id, workspaceURL: workspaceURL)
        }
        session.write(project)
    }

    func remove(_ id: UUID) {
        guard var workspace = session.workspace else { return }
        if let project = workspace.projects.first(where: { $0.id == id }), let url = session.url {
            runner.stop(runner.state(for: project, workspaceURL: url).id)
        }
        workspace.projects.removeAll { $0.id == id }
        session.write(workspace)
    }

    /// Le pide al runner el estado de cada subproyecto para que el panel de procesos
    /// tenga una fila desde el principio, antes de que se ejecute nada.
    func warmUp(_ projects: [CodeProject]) {
        guard let url = session.url else { return }
        for project in projects { _ = runner.state(for: project, workspaceURL: url, workspaceName: session.workspace?.name ?? "") }
    }

    /// Arranca todos los ejecutables cuyo comando esté permitido.
    func startAll() {
        QAProbe.action("process.startAll.request", ["projects": QAField.count(session.runnableProjects.count)])
        guard let workspaceURL = session.url else { return }
        for project in session.runnableProjects where allowedToRun(project, workspaceURL: workspaceURL) {
            start(project, workspaceURL: workspaceURL)
        }
    }

    /// Arranca el proyecto, o lo detiene si ya está corriendo.
    func toggleRun(_ project: CodeProject) {
        guard let workspaceURL = session.url else { return }
        if runner.state(for: project, workspaceURL: workspaceURL).status.active {
            QAProbe.action("process.stop.request", ["project": project.name])
            runner.stop(runner.state(for: project, workspaceURL: workspaceURL).id)
        } else if allowedToRun(project, workspaceURL: workspaceURL) {
            start(project, workspaceURL: workspaceURL)
        }
    }

    /// El único sitio que le pide un proceso al runner, para que la línea de tiempo diga
    /// siempre qué subproyecto arrancó y con qué comando.
    private func start(_ project: CodeProject, workspaceURL: URL) {
        QAProbe.action("process.start.ok", ["project": project.name,
                                            "command": QAField.text(project.command)])
        runner.start(project, workspaceURL: workspaceURL)
    }

    /// Un comando se confirma la primera vez, y de nuevo si cambia, porque la aprobación
    /// se guarda por hash del comando.
    func allowedToRun(_ project: CodeProject, workspaceURL: URL) -> Bool {
        let trusted = session.url?.standardizedFileURL == workspaceURL.standardizedFileURL ? session.trust == .trusted
            : session.trustStore.trust(for: workspaceURL) == .trusted
        guard trusted else {
            QAProbe.failure("process.start.rejected", "proyecto en solo lectura", ["project": project.name])
            session.errors.report(message: "El proyecto está en solo lectura. Confiá en él para ejecutar procesos.")
            return false
        }
        if session.trustStore.isApproved(command: project.commandApproval, project: project.id, workspaceURL: workspaceURL) {
            QAProbe.action("process.command.approved", ["project": project.name, "asked": QAField.bool(false)])
            return true
        }
        let directory = project.executionDirectory(relativeTo: workspaceURL)
        let decision = confirmCommand(CommandPrompt(project: project.name, command: project.commandApproval,
                                                    directory: directory.path))
        QAProbe.dialog("dialog.process.confirmCommand", answer: decision.qaAnswer,
                       ["project": project.name, "command": QAField.text(project.command)])
        switch decision {
        case .cancel:
            QAProbe.action("process.start.cancelled", ["project": project.name])
            return false
        case .once:
            return true
        case .always:
            session.trustStore.approve(command: project.commandApproval, project: project.id, workspaceURL: workspaceURL)
            return true
        }
    }
}
