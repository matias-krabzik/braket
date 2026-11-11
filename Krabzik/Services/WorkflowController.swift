import Foundation
import Observation

@MainActor @Observable
final class WorkflowController {
    var file = WorkflowFile()
    var selectedID: UUID?
    var selectedNodeID: UUID?
    var editing = false
    var isRunning = false
    var activeNodeID: UUID?
    var visited: [UUID: RunStatus] = [:]
    var log = ""
    var error = ""
    @ObservationIgnored private var workspaceURL: URL?
    @ObservationIgnored private var rootURL: URL?
    @ObservationIgnored private var baseline: [URL: Data] = [:]
    @ObservationIgnored private var runner: ProcessRunner?
    @ObservationIgnored private var activeProcess: UUID?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var cancelled = false

    var selected: Workflow? { file.workflows.first { $0.id == selectedID } }
    var directoryURL: URL? { rootURL?.appendingPathComponent(".braket/automations", isDirectory: true) }
    func storageURL(for flow: Workflow) -> URL? {
        directoryURL?.appendingPathComponent("\(flow.id.uuidString.lowercased()).flow.json")
    }

    func configure(_ url: URL, root: URL, selectedFile: URL? = nil) {
        guard !isRunning else { return }
        let changed = workspaceURL != url || rootURL != root
        workspaceURL = url
        rootURL = root
        do {
            if changed {
                var flows: [Workflow] = []
                baseline = [:]
                if let directoryURL, FileManager.default.fileExists(atPath: directoryURL.path) {
                    let files = try FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)
                        .filter { $0.lastPathComponent.hasSuffix(".flow.json") }.sorted { $0.path < $1.path }
                    guard files.count <= 24 else { throw WorkflowError.invalid("Demasiados flujos.") }
                    for path in files {
                        let data = try Data(contentsOf: path)
                        guard data.count <= 256_000 else { throw WorkflowError.invalid("Archivo de flujo demasiado grande.") }
                        let flow = try JSONDecoder().decode(Workflow.self, from: data)
                        baseline[path] = data
                        guard path.standardizedFileURL.path == storageURL(for: flow)?.standardizedFileURL.path
                            else { throw WorkflowError.invalid("El nombre del archivo no coincide con el flujo.") }
                        flows.append(flow)
                    }
                }
                if flows.isEmpty {
                    let legacy = url.deletingLastPathComponent().appendingPathComponent(".braket/workflows.json")
                    if FileManager.default.fileExists(atPath: legacy.path) {
                        let data = try Data(contentsOf: legacy)
                        guard data.count <= 256_000 else { throw WorkflowError.invalid("Archivo anterior demasiado grande.") }
                        flows = try JSONDecoder().decode(WorkflowFile.self, from: data).workflows
                    } else { flows = [.first()] }
                }
                file = WorkflowFile(workflows: flows)
                try file.validate()
                selectedID = flows.first?.id
                selectedNodeID = nil
            }
            if let selectedFile,
               let match = file.workflows
               .first(where: { storageURL(for: $0)?.standardizedFileURL.path == selectedFile.standardizedFileURL.path }) {
                selectedID = match.id
            }
            error = ""
        } catch { file = WorkflowFile()
        selectedID = nil
        self.error = error.localizedDescription }
    }

    func save() {
        do {
            try file.validate()
            guard let directoryURL else { throw WorkflowError.invalid("No hay un proyecto abierto.") }
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            for flow in file.workflows {
                guard let path = storageURL(for: flow) else { continue }
                let current = try? Data(contentsOf: path)
                guard current == baseline[path] else {
                    throw WorkflowError
                        .invalid("El archivo del flujo cambió fuera de Braket. Cerrá y volvé a abrir el proyecto antes de guardar.")
                }
                let data = try JSONEncoder().encode(flow)
                guard data.count <= 256_000 else { throw WorkflowError.invalid("El flujo excede 256 KB.") }
                try data.write(to: path, options: .atomic)
                baseline[path] = data
            }
            error = ""
        } catch { self.error = error.localizedDescription }
    }

    func run(workspace: URL, root: URL, runner: ProcessRunner, trusted: Bool) {
        guard trusted, !isRunning, let selected else { return }
        do { try file.validate() } catch { self.error = error.localizedDescription
        return }
        self.runner = runner
        cancelled = false
        visited = [:]
        log = ""
        error = ""
        editing = false
        isRunning = true
        task = Task { await execute(selected, workspace: workspace, root: root, runner: runner) }
    }

    func stop() {
        cancelled = true
        if let activeProcess { runner?.stop(activeProcess) }
    }

    private func execute(_ flow: Workflow, workspace: URL, root: URL, runner: ProcessRunner) async {
        defer { isRunning = false
        activeNodeID = nil
        activeProcess = nil }
        var current = flow.nodes.first { $0.kind == .start }?.id
        var previousSucceeded = true
        var transitions = 0
        while let id = current, !cancelled {
            transitions += 1
            guard transitions <= 100, let node = flow.nodes.first(where: { $0.id == id }) else {
                error = "El flujo tiene un ciclo o una conexión rota."
                return
            }
            activeNodeID = id
            log += "\n▸ \(node.title)\n"
            switch node.kind {
            case .start:
                visited[id] = .exited(0)
                current = node.next
            case .decision:
                visited[id] = .exited(0)
                log += previousSucceeded ? "Sí\n" : "No\n"
                current = previousSucceeded ? node.next : node.no
            case .end:
                visited[id] = previousSucceeded ? .exited(0) : .exited(1)
                log += "Fin: \(node.title)\n"
                current = nil
            case .script:
                guard !node.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    error = "El bloque \(node.title) no tiene comando."
                    visited[id] = .failed(error)
                    return
                }
                let project = CodeProject(id: node.id, name: node.title, path: root.path, kind: .files, command: node.command)
                runner.start(project, workspaceURL: workspace)
                activeProcess = node.id
                let run = runner.state(for: node.id)
                while run.status.active, !cancelled { try? await Task.sleep(for: .milliseconds(100)) }
                if cancelled { runner.stop(node.id)
                break }
                visited[id] = run.status
                log += run.output + "\n"
                previousSucceeded = run.status == .exited(0)
                current = node.next
            }
        }
        if cancelled { log += "\nEjecución detenida.\n" }
    }
}
