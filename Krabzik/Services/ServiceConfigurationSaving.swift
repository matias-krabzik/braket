import Foundation

extension WorkspaceController {
    /// Merge only edited execution settings, preserving unrelated external changes and rejecting concurrent service edits.
    func saveServices(_ changed: [CodeProject], expected: [CodeProject], at url: URL) throws {
        guard trust.trust(for: url) == .trusted else { throw DatabaseFailure("El proyecto está en solo lectura.") }
        var model = try Workspace.read(from: url)
        let store = ServiceEnvironmentStore()
        for edited in changed {
            guard let index = model.projects.firstIndex(where: { $0.id == edited.id }),
                  let original = expected.first(where: { $0.id == edited.id }) else {
                throw DatabaseFailure("El subproyecto ya no existe. Volvé a abrir la configuración.")
            }
            let current = model.projects[index]
            guard current.services == original.services, current.command == original.command,
                  current.runConfiguration == original.runConfiguration else {
                throw DatabaseFailure("Los servicios cambiaron fuera de esta pantalla. Volvé a abrirla antes de guardar.")
            }
            model.projects[index].services = edited.services
            model.projects[index].command = ""
            model.projects[index].runConfiguration = nil
        }
        try model.checkFormat()
        for edited in changed {
            for service in edited.configuredServices { try store.save(service.variables, serviceID: service.id, workspace: url) }
        }
        if url == workspaceURL {
            guard session.write(model) else { throw DatabaseFailure("No se pudo guardar el proyecto.") }
            projects.warmUp(model.projects)
        } else { try model.write(to: url) }
        openWorkspaceModels[url] = model
        for execution in model.projects.flatMap(\.executionProjects) {
            _ = runner.state(for: execution, workspaceURL: url, workspaceName: model.name)
        }
        for edited in changed {
            for service in edited.configuredServices {
                var execution = service.executionProject(in: edited)
                var config = execution.runConfiguration ?? RunConfiguration()
                for variable in service.variables { config.environment[variable.name] = variable.value }
                execution.runConfiguration = config
                if let php = service.php {
                    let shared = try terminals.sharedEnvironment(for: url)
                    execution.command = php.command(id: service.id,
                                                    environmentKeys: Array(Set(Array(shared.keys) + Array(config.environment.keys))))
                }
                trust.approve(command: execution.commandApproval, project: execution.id, workspaceURL: url)
            }
            for old in expected.first(where: { $0.id == edited.id })?.configuredServices ?? [] {
                let remaining = edited.configuredServices.first { $0.id == old.id }?.variables ?? []
                store.remove(old.variables.filter { item in !remaining.contains { $0.id == item.id } },
                             serviceID: old.id, workspace: url)
            }
        }
        // Removed services cannot linger in the running process list.
        let available = Set(model.projects.flatMap(\.executionProjects).map(\.id))
        for run in Array(runner.runs.values) where run.workspaceURL == url && !available.contains(run.projectID) {
            runner.stop(run.id)
            if !run.status.active { runner.runs.removeValue(forKey: run.id) }
            else {
                Task { @MainActor in
                    while run.status.active { try? await Task.sleep(for: .milliseconds(100)) }
                    guard let latest = try? Workspace.read(from: url),
                          !latest.projects.flatMap(\.executionProjects).contains(where: { $0.id == run.projectID }) else { return }
                    runner.runs.removeValue(forKey: run.id)
                }
            }
        }
    }
}
