import Foundation

extension ProjectLibrary {
    /// A validated topological plan starts prerequisites first and waits for their own listening port when configured.
    func startServices(_ parent: CodeProject, workspaceURL: URL, serviceID: UUID? = nil, automatic: Bool = false) {
        do {
            let definitions = parent.configuredServices
            let plan = try ServicePlan.order(definitions, targets: serviceID.map { [$0] } ?? definitions.map(\.id))
            guard let last = plan.last else { return }
            let shared = try inheritedEnvironment(workspaceURL)
            let executions = try plan.map { definition -> CodeProject in
                var execution = parent.services == nil ? parent : definition.executionProject(in: parent)
                let variables = try ServiceEnvironmentStore().hydrate(definition.variables, serviceID: definition.id,
                                                                      workspace: workspaceURL)
                var config = execution.runConfiguration ?? RunConfiguration()
                for variable in variables { config.environment[variable.name] = variable.value }
                if !variables.isEmpty { execution.runConfiguration = config }
                if let php = definition.php {
                    execution.command = php.command(id: definition.id,
                                                    environmentKeys: Array(Set(Array(shared.keys) + Array(config.environment.keys))))
                }
                return execution
            }
            for execution in executions {
                if automatic {
                    guard session.trustStore.trust(for: workspaceURL) == .trusted,
                          session.trustStore.isApproved(command: execution.commandApproval, project: execution.id,
                                                        workspaceURL: workspaceURL) else { return }
                } else if !allowedToRun(execution, workspaceURL: workspaceURL) { return }
            }
            guard let control = executions.reversed().map({ runner.state(for: $0, workspaceURL: workspaceURL) })
                .first(where: { !$0.status.active && !$0.pendingRestart }) else { return }
            control.pendingRestart = true
            let generation = control.generation
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer { if control.generation == generation { control.pendingRestart = false } }
                do {
                    for (definition, execution) in zip(plan, executions) {
                        guard control.pendingRestart, control.generation == generation else { return }
                        let state = runner.state(for: execution, workspaceURL: workspaceURL)
                        if !state.status.active {
                            QAProbe.action("process.start.ok", ["project": execution.name, "command": QAField.text(execution.command)])
                            let inherited = shared.filter { execution.runConfiguration?.environment[$0.key] == nil }
                            runner.start(execution, workspaceURL: workspaceURL, environment: inherited)
                        }
                        if definition.id != last.id {
                            try await waitForService(definition, run: state, control: control, generation: generation)
                        }
                    }
                } catch {
                    guard control.generation == generation else { return }
                    control.status = .failed(error.localizedDescription)
                    control.append("\nNo se pudo iniciar el servicio: \(error.localizedDescription)\n")
                }
            }
        } catch { session.errors.report(error) }
    }
    private func waitForService(_ definition: ServiceConfiguration, run: ProjectRun, control: ProjectRun,
                                generation: UUID) async throws {
        let deadline = ContinuousClock.now + .seconds(definition.dependencyTimeout)
        let inspection = ProcessInspection()
        // Let an immediate failure (including a failed pre-script) reach the process runner first.
        try await Task.sleep(for: .milliseconds(150))
        while ContinuousClock.now < deadline {
            guard control.pendingRestart, control.generation == generation else { throw CancellationError() }
            if !run.status.active && !run.pendingRestart {
                if run.status == .exited(0), (definition.php?.effectivePort ?? definition.configuration.expectedPort) == nil { return }
                throw DatabaseFailure("La dependencia «\(definition.name)» no está activa. Revisá sus logs.")
            }
            if !definition.waitForPort || (definition.php?.effectivePort ?? definition.configuration.expectedPort) == nil { return }
            if let php = definition.php, php.environment != .local, let project = run.project, let url = run.workspaceURL {
                if await PHPServiceProbe.ready(php, directory: project.executionDirectory(relativeTo: url)) { return }
                try await Task.sleep(for: .milliseconds(250))
                continue
            }
            let listeners = await inspection.listeners()
            if listeners
                .contains(where: {
                $0.port == (definition.php?.effectivePort ?? definition.configuration.expectedPort) && $0.group == run.processID }) {
                return }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw DatabaseFailure("Se agotó la espera de «\(definition.name)» (\(definition.dependencyTimeout) s).")
    }
}
