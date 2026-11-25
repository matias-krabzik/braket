import Foundation

extension WorkspaceController {
    /// Uses the project's current configuration and its existing trust/command approval gate.
    func startManagedProcess(_ run: ProjectRun, restart: Bool = false) {
        guard let url = run.workspaceURL else { return }
        do {
            let model = try Workspace.read(from: url)
            guard let project = model.projects.first(where: {
                $0.id == (run.project?.serviceParentID ?? run.projectID) || $0.configuredServices.contains { $0.id == run.projectID }
            }) else { return }
            if restart {
                runner.stop(run.id)
                run.pendingRestart = true
                let generation = run.generation
                Task { @MainActor in
                    while run.status.active {
                        try? await Task.sleep(for: .milliseconds(100))
                        guard run.pendingRestart, run.generation == generation else { return }
                    }
                    guard run.pendingRestart, run.generation == generation else { return }
                    run.pendingRestart = false
                    projects.startServices(project, workspaceURL: url, serviceID: run.projectID)
                }
            } else { projects.startServices(project, workspaceURL: url, serviceID: run.projectID) }
        } catch { errors.report(error) }
    }

    @discardableResult func saveRunConfiguration(_ project: CodeProject, for run: ProjectRun, restart: Bool) -> Bool {
        guard let url = run.workspaceURL, trust.trust(for: url) == .trusted else { return false }
        do {
            var model = try Workspace.read(from: url)
            guard let index = model.projects.firstIndex(where: { $0.id == project.id }) else { return false }
            // Only execution fields are changed, preserving unrelated edits made on disk.
            model.projects[index].command = project.command
            model.projects[index].runConfiguration = project.runConfiguration
            try model.checkFormat()
            if url == workspaceURL {
                guard session.write(model) else { return false }
            } else { try model.write(to: url) }
            openWorkspaceModels[url] = model
            trust.approve(command: project.commandApproval, project: project.id, workspaceURL: url)
            run.project = model.projects[index]
            if restart { startManagedProcess(run, restart: true) }
            return true
        } catch { errors.report(error)
            return false
        }
    }

    func refreshManagedPorts() async {
        let listeners = await processManager.inspection.listeners()
        guard !Task.isCancelled else { return }
        processManager.listeners = listeners
        for run in runner.runs.values {
            if let php = run.project?.servicePHP, php.environment != .local, php.servesHTTP,
               run.status.active, let project = run.project, let url = run.workspaceURL,
               await PHPServiceProbe.ready(php, directory: project.executionDirectory(relativeTo: url)) {
                run.ports = [php.publishedPort]
                run.portConflict = ""
                continue
            }
            run.ports = run.processID > 0 ? Array(Set(listeners.filter { $0.group == run.processID }.map(\.port))).sorted() : []
            if let port = run.project?.runConfiguration?.expectedPort,
               let owner = listeners.first(where: { $0.port == port && $0.group != run.processID }) {
                run.portConflict = "Puerto \(port) ocupado por \(owner.command) (PID \(owner.pid))"
            } else { run.portConflict = "" }
        }
    }
}
