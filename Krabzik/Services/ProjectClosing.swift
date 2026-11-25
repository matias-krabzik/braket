import Foundation
import Observation

@MainActor @Observable
final class ProjectClosing {
    enum Phase { case confirmation, preparing, stopping, closing, closed, cancelled, failed }
    let controller: WorkspaceController
    let url: URL
    let name: String
    var processes: [CodeProject]
    var phase = Phase.confirmation
    var canForce = false
    var failure = ""

    init(controller: WorkspaceController, url: URL) {
        self.controller = controller
        self.url = url
        let model = controller.projectModel(for: url)
        name = model?.name ?? url.deletingPathExtension().lastPathComponent
        var items = model?.projects.flatMap(\.executionProjects) ?? []
        for run in controller.runner.runs.values where run.workspaceURL == url && (run.status.active || run.pendingRestart) {
            if !items.contains(where: { $0.id == run.projectID }) {
                items.append(CodeProject(id: run.projectID, name: run.name, path: ".", kind: .files, command: ""))
            }
        }
        processes = items
    }

    func run(for id: UUID) -> ProjectRun? {
        guard let run = controller.runner.runs.values.first(where: { $0.projectID == id && $0.workspaceURL == url }) else { return nil }
        return run
    }

    var hasActiveProcesses: Bool { processes.contains { run(for: $0.id).map { $0.status.active || $0.pendingRestart } == true } }

    func confirm(keepProcesses: Bool = false) async {
        guard phase == .confirmation, controller.session.beginSwitch() else { return }
        var ownsTransition = true
        defer { if ownsTransition { controller.session.endSwitch() } }
        phase = .preparing
        if controller.workspaceURL == url {
            if controller.agent.isRunning {
                guard controller.session.dialogs.confirmStopAgent() else { phase = .cancelled
                return }
                controller.agent.shutdown()
            }
            guard await controller.files.resolveDirty(), await controller.database.prepareToLeave(closeIdleConnections: false) else {
                phase = .cancelled
                return
            }
        }
        guard !Task.isCancelled else { return }
        if keepProcesses {
            controller.session.endSwitch()
            ownsTransition = false
            await controller.closeWorkspace(url, prepared: true)
            phase = controller.openWorkspaceURLs.contains(url) ? .failed : .closed
            return
        }
        phase = .stopping
        for run in controller.runner.runs.values where run.workspaceURL == url && (run.status.active || run.pendingRestart) {
            if !processes.contains(where: { $0.id == run.projectID }) {
                processes.append(CodeProject(id: run.projectID, name: run.name, path: ".", kind: .files, command: ""))
            }
        }
        for process in processes where run(for: process.id).map({ $0.status.active || $0.pendingRestart }) == true {
            if let run = run(for: process.id) { controller.runner.stop(run.id, automaticallyForce: false) }
        }
        let start = ContinuousClock.now
        while hasActiveProcesses {
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            canForce = start.duration(to: .now) >= .seconds(2)
        }
        guard !Task.isCancelled else { return }
        phase = .closing
        controller.session.endSwitch()
        ownsTransition = false
        await controller.closeWorkspace(url, prepared: true)
        if controller.openWorkspaceURLs.contains(url) {
            failure = controller.errors.current?.message ?? "No se pudo cerrar el proyecto."
            phase = .failed
        } else {
            phase = .closed
        }
    }

    func force(_ id: UUID) {
        guard phase == .stopping, canForce, run(for: id)?.status.active == true, processes.contains(where: { $0.id == id }) else { return }
        if let run = run(for: id) { controller.runner.forceStop(run.id) }
    }
}
