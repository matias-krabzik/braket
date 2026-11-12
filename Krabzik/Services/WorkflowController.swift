import Foundation
import Observation

struct WorkflowTransition: Hashable {
    let from: UUID
    let to: UUID
    let isNo: Bool
}

struct WorkflowStepResult: Equatable {
    let summary: String
    let detail: String
    let successful: Bool
}

@MainActor @Observable
final class WorkflowController {
    var file = WorkflowFile()
    var selectedID: UUID?
    var selectedNodeID: UUID?
    var editing = false
    var isRunning = false
    var activeNodeID: UUID?
    var visited: [UUID: RunStatus] = [:]
    var traversedTransitions: Set<WorkflowTransition> = []
    var results: [UUID: WorkflowStepResult] = [:]
    var inputJSON: [UUID: String] = [:]
    var outputJSON: [UUID: String] = [:]
    var executionOrder: [UUID] = []
    var log = ""
    var error = ""
    @ObservationIgnored private var workspaceURL: URL?
    @ObservationIgnored private var rootURL: URL?
    @ObservationIgnored private var baseline: [URL: Data] = [:]
    @ObservationIgnored private var runner: ProcessRunner?
    @ObservationIgnored private let aiRunner = WorkflowCodexRunner()
    @ObservationIgnored private var activeAI = false
    @ObservationIgnored private var activeProcess: UUID?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var cancelled = false
    /// Quién pregunta por un script sin aprobar. Por defecto **niega**, igual que
    /// `ProjectLibrary.confirmCommand`: la interfaz inyecta el diálogo real en `forApp()`.
    @ObservationIgnored var confirmCommand: @MainActor (CommandPrompt) -> CommandDecision = { _ in .cancel }

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
                if let directoryURL {
                    try WorkflowStorage.requireRealFiles([directoryURL.deletingLastPathComponent(), directoryURL])
                }
                if let directoryURL, FileManager.default.fileExists(atPath: directoryURL.path) {
                    let files = try FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)
                        .filter { $0.lastPathComponent.hasSuffix(".flow.json") }.sorted { $0.path < $1.path }
                    guard files.count <= 24 else { throw WorkflowError.invalid("Demasiados flujos.") }
                    try WorkflowStorage.requireRealFiles(files)
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
            try WorkflowStorage.requireRealFiles([directoryURL.deletingLastPathComponent(), directoryURL])
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            for flow in file.workflows {
                guard let path = storageURL(for: flow) else { continue }
                try WorkflowStorage.requireRealFiles([path])
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

    /// `approvals` es donde se recuerda lo que el usuario aprobó. Confiar en el proyecto no
    /// alcanza para correr un script: ver `WorkflowScriptApproval`.
    func run(workspace: URL, root: URL, runner: ProcessRunner, trusted: Bool, approvals: TrustStore,
             agent: AgentController? = nil,
             trigger: WorkflowKind = .start) {
        guard trusted, !isRunning, let selected else { return }
        guard trigger.isTrigger, selected.nodes.contains(where: { $0.kind == trigger }) else { return }
        do { try file.validate() } catch { self.error = error.localizedDescription
        return }
        for node in selected.scripts(from: trigger) {
            let approval = WorkflowScriptApproval(node: node, root: root)
            guard approval.authorize(store: approvals, workspaceURL: workspace, ask: confirmCommand) else {
                self.error = "No se ejecutó: falta aprobar el script «\(node.title)»."
                return
            }
        }
        self.runner = runner
        cancelled = false
        visited = [:]
        traversedTransitions = []
        results = [:]
        inputJSON = [:]
        outputJSON = [:]
        executionOrder = []
        log = ""
        error = ""
        editing = false
        isRunning = true
        task = Task { await execute(selected, workspace: workspace, root: root, runner: runner,
                                    agent: agent, trigger: trigger) }
    }

    func testNode(_ id: UUID, input: String, workspace: URL, root: URL, runner: ProcessRunner,
                  trusted: Bool, approvals: TrustStore, agent: AgentController? = nil) {
        guard trusted, !isRunning, let selected,
              let node = selected.nodes.first(where: { $0.id == id }) else { return }
        results.removeValue(forKey: id)
        inputJSON.removeValue(forKey: id)
        outputJSON.removeValue(forKey: id)
        error = ""
        do {
            try file.validate()
            guard input.utf8.count <= 64_000,
                  let data = input.data(using: .utf8),
                  let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw WorkflowError.invalid("La entrada debe ser un objeto JSON válido de hasta 64 KB.")
            }
            if node.kind == .script {
                let approval = WorkflowScriptApproval(node: node, root: root)
                guard approval.authorize(store: approvals, workspaceURL: workspace, ask: confirmCommand) else {
                    throw WorkflowError.invalid("No se ejecutó: falta aprobar el script «\(node.title)».")
                }
            }
            self.runner = runner
            cancelled = false
            visited = [:]
            traversedTransitions = []
            results = [:]
            inputJSON = [:]
            outputJSON = [:]
            executionOrder = []
            log = ""
            error = ""
            isRunning = true
            task = Task { await execute(selected, workspace: workspace, root: root, runner: runner,
                                        agent: agent, trigger: node.kind,
                                        startingNodeID: id, initialPayload: payload, singleStep: true) }
        } catch { self.error = error.localizedDescription }
    }

    func stop() {
        cancelled = true
        if let activeProcess { runner?.stop(activeProcess) }
        if activeAI { aiRunner.stop() }
    }

    private func execute(_ flow: Workflow, workspace: URL, root: URL, runner: ProcessRunner,
                         agent: AgentController?, trigger: WorkflowKind,
                         startingNodeID: UUID? = nil, initialPayload: [String: Any] = [:],
                         singleStep: Bool = false) async {
        defer { isRunning = false
        activeNodeID = nil
        activeProcess = nil
        activeAI = false }
        var current = startingNodeID ?? flow.nodes.first { $0.kind == trigger }?.id
        var previousSucceeded = true
        var previousOutput = initialPayload["stdout"] as? String ?? initialPayload["text"] as? String ?? ""
        var payload = initialPayload
        var previousExitCode: Int32? = (initialPayload["exitCode"] as? NSNumber).map { $0.int32Value }
        var transitions = 0
        while let id = current, !cancelled {
            transitions += 1
            guard transitions <= 100, let node = flow.nodes.first(where: { $0.id == id }) else {
                error = "El flujo tiene un ciclo o una conexión rota."
                return
            }
            activeNodeID = id
            executionOrder.append(id)
            inputJSON[id] = WorkflowJSON.encode(payload)
            log += "\n▸ \(node.title)\n"
            switch node.kind {
            case .start, .event, .schedule:
                visited[id] = .exited(0)
                results[id] = WorkflowStepResult(summary: "OK", detail: "Disparador activado.", successful: true)
                previousOutput = "ok"
                payload = ["project": root.lastPathComponent, "trigger": node.kind.rawValue]
                outputJSON[id] = WorkflowJSON.encode(payload)
                previousExitCode = 0
                current = node.next
                recordTransition(from: id, to: current, isNo: false)
            case .decision:
                do {
                    let matches = try node.condition.evaluate(previousSucceeded: previousSucceeded,
                                                              output: previousOutput, exitCode: previousExitCode,
                                                              json: WorkflowJSON.encode(payload))
                    visited[id] = .exited(0)
                    let input = WorkflowJSON.encode(payload)
                    let left = try node.condition.left.resolve(output: previousOutput,
                                                               exitCode: previousExitCode,
                                                               environment: ProcessInfo.processInfo.environment,
                                                               json: input)
                    let right = try node.condition.right.resolve(output: previousOutput,
                                                                 exitCode: previousExitCode,
                                                                 environment: ProcessInfo.processInfo.environment,
                                                                 json: input)
                    results[id] = WorkflowStepResult(summary: matches ? "Sí" : "No",
                                                     detail: "\(left.prefix(160)) \(node.condition.operation.title) \(right.prefix(160))\n\(matches ? "Se cumplió" : "No se cumplió") la condición.",
                                                     successful: true)
                    log += matches ? "Sí\n" : "No\n"
                    previousSucceeded = true
                    outputJSON[id] = WorkflowJSON.encode(payload)
                    current = matches ? node.next : node.no
                    recordTransition(from: id, to: current, isNo: !matches)
                } catch {
                    self.error = error.localizedDescription
                    visited[id] = .failed(error.localizedDescription)
                    results[id] = WorkflowStepResult(summary: "Error", detail: error.localizedDescription,
                                                     successful: false)
                    log += "Error: \(error.localizedDescription)\n"
                    return
                }
            case .end:
                outputJSON[id] = WorkflowJSON.encode(payload)
                visited[id] = previousSucceeded ? .exited(0) : .exited(1)
                results[id] = WorkflowStepResult(summary: "Finalizado",
                                                 detail: "El flujo terminó en «\(node.title)».",
                                                 successful: previousSucceeded)
                log += "Fin: \(node.title)\n"
                current = nil
            case .script:
                guard !node.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    error = "El bloque \(node.title) no tiene comando."
                    visited[id] = .failed(error)
                    results[id] = WorkflowStepResult(summary: "Error", detail: error, successful: false)
                    return
                }
                let directory = node.resolvedDirectory(root: root)
                let project = CodeProject(id: node.id, name: node.title, path: directory.path,
                                          kind: .files, command: node.command)
                var environment = Dictionary(uniqueKeysWithValues: node.settings.environment.map { ($0.name, $0.value) })
                environment["BRAKET_INPUT"] = WorkflowJSON.encode(payload)
                environment["BRAKET_PREVIOUS_OUTPUT"] = previousOutput
                environment["BRAKET_PREVIOUS_EXIT_CODE"] = previousExitCode.map(String.init) ?? ""
                runner.start(project, workspaceURL: workspace, environment: environment)
                activeProcess = node.id
                let run = runner.state(for: node.id)
                let deadline = node.settings.timeoutSeconds > 0
                    ? Date().addingTimeInterval(TimeInterval(node.settings.timeoutSeconds)) : nil
                var timedOut = false
                while run.status.active, !cancelled {
                    if let deadline, Date() >= deadline, !timedOut {
                        timedOut = true
                        runner.stop(node.id)
                    }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                if cancelled { runner.stop(node.id)
                visited[id] = .failed("Detenido")
                results[id] = WorkflowStepResult(summary: "Detenido", detail: run.output, successful: false)
                break }
                visited[id] = timedOut ? .failed("Tiempo límite de \(node.settings.timeoutSeconds) s agotado") : run.status
                log += run.output + "\n"
                if timedOut { log += "Tiempo límite de \(node.settings.timeoutSeconds) s agotado.\n" }
                let summary: String
                if timedOut { summary = "Tiempo agotado" }
                else if case .exited(let code) = run.status { summary = "Salida \(code)" }
                else { summary = "Error" }
                results[id] = WorkflowStepResult(summary: summary, detail: run.output,
                                                 successful: !timedOut && run.status == .exited(0))
                previousOutput = run.capturedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                if timedOut { previousExitCode = 124 }
                else if case .exited(let code) = run.status { previousExitCode = code }
                else { previousExitCode = 1 }
                previousSucceeded = !timedOut && run.status == .exited(0)
                payload = ["stdout": previousOutput, "stderr": "", "exitCode": Int(previousExitCode ?? 1)]
                outputJSON[id] = WorkflowJSON.encode(payload)
                current = node.next
                recordTransition(from: id, to: current, isNo: false)
            case .files:
                do {
                    let processed = try WorkflowFileProcessor.process(payload, settings: node.fileSettings,
                                                                       root: root, preview: singleStep)
                    payload = processed.payload
                    outputJSON[id] = WorkflowJSON.encode(payload)
                    previousSucceeded = processed.failed == 0
                    previousExitCode = previousSucceeded ? 0 : 1
                    previousOutput = processed.detail
                    let summary = processed.failed > 0 ? "\(processed.failed) con error"
                        : singleStep ? "Vista previa · \(processed.saved)"
                        : "\(processed.saved) guardados"
                    visited[id] = previousSucceeded ? .exited(0) : .exited(1)
                    results[id] = WorkflowStepResult(summary: summary, detail: processed.detail,
                                                     successful: previousSucceeded)
                    log += processed.detail + "\n"
                } catch {
                    let message = error.localizedDescription
                    payload["fileResults"] = []
                    payload["fileSummary"] = ["total": 0, "processed": 0, "failed": 1,
                                              "preview": singleStep]
                    outputJSON[id] = WorkflowJSON.encode(payload)
                    previousSucceeded = false
                    previousExitCode = 1
                    previousOutput = message
                    visited[id] = .failed(message)
                    results[id] = WorkflowStepResult(summary: "Error", detail: message, successful: false)
                    log += "Error: \(message)\n"
                }
                current = node.next
                recordTransition(from: id, to: current, isNo: false)
            case .ai:
                do {
                    guard !node.ai.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw WorkflowError.invalid("El bloque \(node.title) necesita un prompt.")
                    }
                    guard let agent else {
                        throw WorkflowError.invalid("Conectá Codex para ejecutar este bloque.")
                    }
                    activeAI = true
                    let text = try await aiRunner.run(prompt: node.ai.prompt, input: WorkflowJSON.encode(payload),
                                                      model: node.ai.model, root: root, agent: agent)
                    activeAI = false
                    if cancelled { break }
                    let delivered = try WorkflowAIOutput.deliver(text, settings: node.ai, root: root)
                    previousOutput = delivered.output
                    payload = WorkflowJSON.decode(delivered.output)
                    outputJSON[id] = delivered.output
                    previousExitCode = 0
                    previousSucceeded = true
                    visited[id] = .exited(0)
                    results[id] = WorkflowStepResult(summary: "Codex · OK", detail: delivered.detail,
                                                     successful: true)
                    log += "Codex terminó. Resultado JSON disponible para el siguiente nodo.\n"
                } catch {
                    activeAI = false
                    let message = cancelled ? "Ejecución detenida." : error.localizedDescription
                    previousOutput = ""
                    payload = ["error": message]
                    outputJSON[id] = WorkflowJSON.encode(payload)
                    previousExitCode = 1
                    previousSucceeded = false
                    visited[id] = .failed(message)
                    results[id] = WorkflowStepResult(summary: cancelled ? "Detenido" : "Codex · Error",
                                                     detail: message, successful: false)
                    log += "Codex: \(message)\n"
                }
                if cancelled { break }
                current = node.next
                recordTransition(from: id, to: current, isNo: false)
            }
            if singleStep { break }
        }
        if cancelled { log += "\nEjecución detenida.\n" }
    }

    private func recordTransition(from: UUID, to: UUID?, isNo: Bool) {
        guard let to else { return }
        traversedTransitions.insert(WorkflowTransition(from: from, to: to, isNo: isNo))
    }
}

enum WorkflowJSON {
    static func encode(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted])
        else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    static func decode(_ text: String) -> [String: Any] {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }
}
