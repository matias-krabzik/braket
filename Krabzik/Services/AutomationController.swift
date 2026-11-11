import Foundation
import Observation

/// Sequential jobs reuse ProcessRunner's process groups, output batching and termination.
@MainActor @Observable
final class AutomationController {
    var root: URL?
    var catalog = AutomationFile()
    var selectedID: UUID?
    var execution: AutomationExecution?
    var history: [AutomationExecution] = []
    var selectedStep = 0
    var currentRun: ProjectRun?
    var message = ""
    var isRunning = false
    var showingConfiguration = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var activeRun: ProjectRun?
    @ObservationIgnored private var runner: ProcessRunner?
    @ObservationIgnored private var cancelled = false
    @ObservationIgnored private var approvedStep: Int?
    @ObservationIgnored private var loadedWorkspace: URL?
    @ObservationIgnored private var baseline = AutomationFile()

    var selected: Automation? { catalog.automations.first { $0.id == selectedID } }
    var canResume: Bool {
        guard !isRunning, let execution, execution.root.standardizedFileURL.path == root?.standardizedFileURL.path,
              [.failed, .interrupted, .cancelled].contains(execution.phase),
              execution.automation.steps.indices.contains(execution.stepIndex) else { return false }
        return execution.automation.steps[execution.stepIndex].retryable
    }

    func configure(workspace: URL, root proposed: URL) {
        guard !isRunning else { return }
        let proposed = proposed.standardizedFileURL
        guard loadedWorkspace != workspace || root != proposed else { return }
        loadedWorkspace = workspace
        root = proposed
        execution = nil
        currentRun = nil
        reload()
    }

    func reload() {
        guard !isRunning, let root else { return }
        do {
            catalog = try AutomationStore(root: root).load()
            baseline = catalog
            if !catalog.automations.contains(where: { $0.id == selectedID }) { selectedID = catalog.automations.first?.id }
            history = try AutomationStore(root: root).history()
            message = ""
        } catch {
            catalog = AutomationFile()
            baseline = catalog
            selectedID = nil
            message = error.localizedDescription
        }
    }

    func save() {
        guard !isRunning, let root else { return }
        do {
            let store = AutomationStore(root: root)
            guard try store.load() == baseline else {
                throw AutomationError.invalid("El archivo cambió fuera de Braket. Recargá antes de guardar.")
            }
            try store.save(catalog)
            baseline = catalog
            message = "Configuración guardada."
        } catch { message = error.localizedDescription }
    }

    func start(_ automation: Automation, parameters: [AutomationVariable], workspace: URL, runner: ProcessRunner) {
        guard !isRunning, let root else { return }
        do {
            try AutomationFile(automations: [automation]).validate()
            try AutomationFile.validateVariables(parameters)
            guard automation.steps.contains(where: \.enabled), automation.steps.filter(\.enabled).allSatisfy({ !$0.command.isEmpty }) else {
                throw AutomationError.invalid("Agregá al menos un paso habilitado con un comando.")
            }
            guard Set(parameters.map(\.name)) == Set(automation.parameters.map(\.name)) else {
                throw AutomationError.invalid("Los parámetros no coinciden con la automatización.")
            }
            execution = AutomationExecution(automation: automation, parameters: parameters, workspaceURL: workspace, root: root,
                                            states: automation.steps.map { $0.enabled ? .pending : .skipped })
            launch(runner)
        } catch { message = error.localizedDescription }
    }

    func resume(workspace: URL, runner: ProcessRunner) {
        guard canResume, execution?.workspaceURL.standardizedFileURL.path == workspace.standardizedFileURL.path else { return }
        launch(runner)
    }

    private func launch(_ runner: ProcessRunner) {
        self.runner = runner
        cancelled = false
        approvedStep = nil
        message = ""
        isRunning = true
        task = Task { await execute(runner) }
    }

    func confirmStep() {
        guard execution?.phase == .waiting else { return }
        approvedStep = execution?.stepIndex
    }

    func cancel(automaticallyForce: Bool = true) {
        guard isRunning else { return }
        cancelled = true
        if let activeRun { runner?.stop(activeRun.id, automaticallyForce: automaticallyForce) }
    }

    func showHistory(_ item: AutomationExecution) {
        guard !isRunning else { return }
        execution = item
        selectedStep = min(item.stepIndex, max(0, item.states.count - 1))
        selectStep(selectedStep)
    }

    func selectStep(_ index: Int) {
        selectedStep = index
        guard let execution, execution.states.indices.contains(index) else { return }
        if isRunning && index == execution.stepIndex { return }
        let run = ProjectRun(id: UUID())
        let file = AutomationStore(root: execution.root).directory(for: execution).appendingPathComponent("step-\(index).log")
        if let data = try? AutomationStore(root: execution.root).boundedRead(file, limit: 250_000) {
            run.append(String(decoding: data, as: UTF8.self))
        }
        currentRun = run
    }

    private func checkpoint() throws {
        guard let execution else { return }
        try AutomationStore(root: execution.root).save(execution)
    }

    private func execute(_ runner: ProcessRunner) async {
        defer {
            isRunning = false
            if let root { history = (try? AutomationStore(root: root).history()) ?? history }
        }
        do {
            guard let initial = execution else { return }
            execution?.phase = .running
            execution?.finished = nil
            try checkpoint()
            for index in initial.stepIndex..<initial.automation.steps.count {
                guard !cancelled else { break }
                let step = initial.automation.steps[index]
                execution?.stepIndex = index
                selectedStep = index
                if !step.enabled { continue }
                if step.requiresConfirmation {
                    execution?.phase = .waiting
                    execution?.states[index] = .waiting
                    currentRun = nil
                    try checkpoint()
                    while approvedStep != index && !cancelled { try await Task.sleep(for: .milliseconds(100)) }
                    guard !cancelled else { break }
                }
                execution?.phase = .running
                execution?.states[index] = .running
                try checkpoint()
                let store = AutomationStore(root: initial.root)
                let outputFile = store.directory(for: initial).appendingPathComponent("outputs-\(index)-\(UUID().uuidString).json")
                let environment = try Self.environment(parameters: initial.parameters, step: step,
                                                       outputs: execution?.outputs ?? [:], root: initial.root, outputFile: outputFile)
                let directory = step.directory.hasPrefix("/") ? URL(fileURLWithPath: step.directory)
                    : initial.root.appendingPathComponent(step.directory)
                var command = step.command
                if !step.nodeVersion.isEmpty {
                    command = "source \"${NVM_DIR:-$HOME/.nvm}/nvm.sh\" --no-use && nvm exec "
                        + Shell.quote(step.nodeVersion) + " /bin/zsh -c " + Shell.quote(command)
                }
                let project = CodeProject(name: step.name, path: directory.path, kind: .files, command: command)
                runner.start(project, workspaceURL: initial.workspaceURL, environment: environment)
                let run = runner.state(for: project.id)
                currentRun = run
                activeRun = run
                let started = ContinuousClock.now
                var timedOut = false
                var lastLog = ContinuousClock.now
                while run.status.active {
                    try await Task.sleep(for: .milliseconds(100))
                    if lastLog.duration(to: .now) > .seconds(1) {
                        try Data(run.output.utf8.suffix(200_000))
                            .write(to: store.directory(for: initial).appendingPathComponent("step-\(index).log"),
                                   options: .atomic)
                        lastLog = .now
                    }
                    if !timedOut && started.duration(to: .now) > .seconds(step.timeoutSeconds) {
                        timedOut = true
                        runner.stop(run.id)
                    }
                }
                try Data(run.output.utf8.suffix(200_000))
                    .write(to: store.directory(for: initial).appendingPathComponent("step-\(index).log"),
                           options: .atomic)
                guard !cancelled else { break }
                guard !timedOut, run.status == .exited(0) else {
                    throw AutomationError.invalid(timedOut ? "Tiempo agotado: \(step.name)" : "\(step.name): \(run.status.label)")
                }
                if FileManager.default.fileExists(atPath: outputFile.path) {
                    let outputs = try JSONDecoder().decode([String: String].self, from: store.boundedRead(outputFile, limit: 65_536))
                    guard outputs.count <= 64, outputs.allSatisfy({ AutomationFile.validKey($0.key) && !$0.value.contains("\0") }) else {
                        throw AutomationError.invalid("El paso produjo resultados inválidos.")
                    }
                    var combined = execution?.outputs ?? [:]
                    combined.merge(outputs) { _, new in new }
                    guard combined.count <= 64, combined.reduce(0, { $0 + $1.key.utf8.count + $1.value.utf8.count }) <= 65_536 else {
                        throw AutomationError.invalid("Los resultados acumulados exceden el límite de 64 KB o 64 variables.")
                    }
                    execution?.outputs = combined
                }
                execution?.states[index] = .succeeded
                execution?.stepIndex = index + 1
                try checkpoint()
            }
            execution?.phase = cancelled ? .cancelled : .succeeded
            if cancelled, let index = execution?.stepIndex, execution?.states.indices.contains(index) == true {
                execution?.states[index] = .cancelled
            }
        } catch {
            if let activeRun {
                runner.stop(activeRun.id)
                while activeRun.status.active { try? await Task.sleep(for: .milliseconds(100)) }
            }
            execution?.phase = cancelled ? .cancelled : .failed
            if let index = execution?.stepIndex, execution?.states.indices.contains(index) == true {
                execution?.states[index] = cancelled ? .cancelled : .failed
            }
            execution?.message = error.localizedDescription
            message = error.localizedDescription
            if !cancelled, let execution, execution.automation.steps.indices.contains(execution.stepIndex) {
                let step = execution.automation.steps[execution.stepIndex]
                let run = currentRun ?? ProjectRun(id: UUID())
                run.append("\nError en «\(step.name)»: \(error.localizedDescription)\n")
                run.append("Directorio: \(step.directory) · Proyecto: \(execution.root.path)\n")
                if case .exited(let code) = run.status, code != 0 {
                    run.append("Revisá la salida del comando anterior (stdout y stderr). "
                               + "El código \(code) por sí solo no indica la causa.\n")
                }
                currentRun = run
                let log = AutomationStore(root: execution.root).directory(for: execution)
                    .appendingPathComponent("step-\(execution.stepIndex).log")
                do { try Data(run.output.utf8.suffix(200_000)).write(to: log, options: .atomic) }
                catch { message += " · No se pudo guardar el detalle: \(error.localizedDescription)" }
            }
        }
        execution?.finished = Date()
        do { try checkpoint() } catch { message = "No se pudo guardar el historial: \(error.localizedDescription)" }
    }

    static func environment(parameters: [AutomationVariable], step: AutomationStep, outputs: [String: String],
                            root: URL, outputFile: URL) throws -> [String: String] {
        try AutomationFile.validateVariables(parameters)
        try AutomationFile.validateVariables(step.environment)
        var values = Dictionary(uniqueKeysWithValues: step.environment.map { ($0.name, $0.value) })
        for parameter in parameters { values["BRAKET_INPUT_" + parameter.name] = parameter.value }
        for (key, value) in outputs { values["BRAKET_OUTPUT_" + key] = value }
        values["BRAKET_PROJECT_DIR"] = root.path
        values["BRAKET_OUTPUT_FILE"] = outputFile.path
        values["BRAKET_RUN_DIR"] = outputFile.deletingLastPathComponent().path
        return values
    }
}
