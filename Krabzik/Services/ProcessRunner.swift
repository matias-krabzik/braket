import Darwin
import Foundation
import Observation

/// En qué estado está el proceso de un subproyecto, con su etiqueta para la interfaz.
enum RunStatus: Equatable {
    case idle, running, stopping, exited(Int32), failed(String)

    var active: Bool { self == .running || self == .stopping }
    var label: String {
        switch self {
        case .idle: return "Detenido"
        case .running: return "En ejecución"
        case .stopping: return "Deteniendo"
        case .exited(let code): return code == 0 ? "Finalizado" : "Salida \(code)"
        case .failed: return "Error"
        }
    }
}

/// El proceso de un subproyecto y su salida acumulada.
///
/// `generation` descarta la salida de un proceso anterior que todavía esté llegando
/// cuando se reinicia el mismo subproyecto. `output` tiene tope (ver `append`).
/// Confinado al main actor; `processID` y `generation` no disparan repintados.
@MainActor @Observable
final class ProjectRun: Identifiable {
    let id: UUID
    var projectID: UUID
    var project: CodeProject?
    var workspaceName = ""
    var startedAt: Date?
    var endedAt: Date?
    var restartAttempts = 0
    var ports: [Int] = []
    var portConflict = ""
    var pendingRestart = false
    var status: RunStatus = .idle
    var output = ""
    var capturedOutput = ""
    var revision = 0
    @ObservationIgnored var workspaceURL: URL?
    @ObservationIgnored var name = ""
    var processID: pid_t = 0
    @ObservationIgnored var generation = UUID()
    @ObservationIgnored var stopGeneration = UUID()

    init(id: UUID) { self.id = id
        projectID = id
    }

    func append(_ text: String) {
        output += text
        if output.utf8.count > 200_000 { output = String(output.suffix(120_000)) }
        revision += 1
    }
}

/// Collects bursts without a permanent timer. At most one UI update per 80 ms.
/// `@unchecked Sendable`: todo el estado mutable (`pending`, `scheduled`, `decoder`) se
/// toca únicamente con `lock` tomado, y `deliver` está aislado al main actor.
private final class OutputBatch: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private var scheduled = false
    private var decoder = UTF8StreamDecoder()
    private let deliver: @MainActor (String) -> Void

    init(deliver: @escaping @MainActor (String) -> Void) { self.deliver = deliver }

    func push(_ data: Data) {
        lock.lock()
        pending.append(data)
        if pending.count > 256_000 { pending = pending.suffix(128_000) }
        let schedule = !scheduled
        scheduled = true
        lock.unlock()
        if schedule {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { self.flush() }
        }
    }

    @MainActor func flush() {
        lock.lock()
        let data = pending
        pending.removeAll(keepingCapacity: true)
        scheduled = false
        lock.unlock()
        let text = decoder.decode(data)
        if !text.isEmpty { deliver(text) }
    }
}

/// Decodifica UTF-8 que llega partido entre lecturas.
///
/// Una lectura de la tubería puede cortar un carácter de varios bytes por la mitad.
/// Guarda la cola incompleta y la antepone a la próxima, así un acento o un emoji no
/// aparecen como basura. No es `Sendable`: vive en el hilo que lee.
struct UTF8StreamDecoder {
    private var remaining = Data()

    mutating func decode(_ bytes: Data) -> String {
        remaining.append(bytes)
        let all = [UInt8](remaining)
        var split = all.count
        if !all.isEmpty {
            var start = all.count - 1
            while start > 0 && all[start] & 0xC0 == 0x80 { start -= 1 }
            let first = all[start]
            let needed = first < 0x80 ? 1 : first & 0xE0 == 0xC0 ? 2 : first & 0xF0 == 0xE0 ? 3 : first & 0xF8 == 0xF0 ? 4 : 1
            if all.count - start < needed { split = start }
        }
        let result = String(decoding: all[..<split], as: UTF8.self)
        remaining = Data(all[split...])
        return result
    }
}

/// Lanza y detiene los procesos de los subproyectos, uno por subproyecto.
///
/// Cada hijo arranca en su **propio grupo de procesos**, así que detenerlo alcanza
/// también a lo que él lanzó (npm, php). Confinado al main actor; la lectura de las
/// tuberías ocurre en colas de fondo y vuelve por `OutputBatch`.
@MainActor @Observable
final class ProcessRunner {
    var runs: [UUID: ProjectRun] = [:]
    private var shuttingDown = false
    var hasActiveProcesses: Bool { runs.values.contains { $0.status.active || $0.pendingRestart } }

    func state(for id: UUID) -> ProjectRun {
        if let run = runs[id] { return run }
        let run = ProjectRun(id: id)
        runs[id] = run
        return run
    }

    func state(for project: CodeProject, workspaceURL: URL, workspaceName: String = "") -> ProjectRun {
        let url = workspaceURL.standardizedFileURL
        let existing = runs.values.first { $0.projectID == project.id && $0.workspaceURL == url }
        let run = existing ?? state(for: runs[project.id]?.workspaceURL == nil ? project.id : UUID())
        run.projectID = project.id
        run.workspaceURL = url
        run.workspaceName = workspaceName.isEmpty ? (run.workspaceName.isEmpty ? url.deletingPathExtension().lastPathComponent
            : run.workspaceName) : workspaceName
        if !run.status.active { run.project = project
            run.name = project.executionName
        }
        return run
    }

    func start(_ project: CodeProject, workspaceURL: URL, environment overrides: [String: String] = [:]) {
        let run = state(for: project, workspaceURL: workspaceURL)
        guard !shuttingDown, !run.status.active, !project.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        run.pendingRestart = false
        let directory = project.executionDirectory(relativeTo: workspaceURL)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            run.status = .failed("Carpeta no disponible")
            run.append("\nNo se encuentra \(directory.path)\n")
            return
        }
        run.project = project
        run.pendingRestart = false
        run.startedAt = Date()
        run.endedAt = nil
        run.ports = []
        run.workspaceURL = workspaceURL.standardizedFileURL
        run.name = project.executionName
        run.generation = UUID()
        let generation = run.generation
        run.output = "$ \(project.executionCommand)\n"
        run.capturedOutput = ""
        run.revision += 1

        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else {
            run.status = .failed("No se pudo abrir la salida")
            return
        }
        let readFD = descriptors[0], writeFD = descriptors[1]
        _ = fcntl(readFD, F_SETFD, FD_CLOEXEC)
        _ = fcntl(writeFD, F_SETFD, FD_CLOEXEC)

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        posix_spawn_file_actions_adddup2(&actions, writeFD, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, writeFD, STDERR_FILENO)
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addclose(&actions, readFD)
        posix_spawn_file_actions_addclose(&actions, writeFD)
        // The child starts its own group atomically; stop reaches npm/PHP descendants too.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        environment["NO_COLOR"] = "1"
        environment["TERM"] = "dumb"
        environment.merge(project.runConfiguration?.environment ?? [:]) { _, new in new }
        environment.merge(overrides) { _, new in new }
        let shell = project.runConfiguration?.shellPath ?? "/bin/zsh"
        let profile = project.runConfiguration?.loadShellProfile ?? true
        let arguments = [shell] + (profile ? ["-l"] : []) + ["-c", project.executionScript(directory: directory)]
        let argv = arguments.map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, shell, &actions, &attributes, argv, envp)
        Darwin.close(writeFD)
        guard result == 0 else {
            Darwin.close(readFD)
            let reason = String(cString: strerror(result))
            Log.process.error("no se pudo lanzar el proceso: \(reason, privacy: .public)")
            run.status = .failed(reason)
            run.append("\(reason)\n")
            return
        }
        let spawnedPID = pid
        run.processID = spawnedPID
        run.status = .running
        // El comando va como privado: lo escribió el usuario y puede traer rutas o tokens.
        Log.process.info("proceso iniciado · pid \(spawnedPID, privacy: .public) · \(project.command, privacy: .private)")
        let batch = OutputBatch { [weak run] text in
            guard let run, run.generation == generation else { return }
            run.append(text)
            run.capturedOutput += text
            if run.capturedOutput.utf8.count > 200_000 {
                run.capturedOutput = String(run.capturedOutput.suffix(120_000))
            }
        }
        DispatchQueue.global(qos: .utility).async {
            var buffer = [UInt8](repeating: 0, count: 16_384)
            while true {
                let count = Darwin.read(readFD, &buffer, buffer.count)
                if count > 0 { batch.push(Data(buffer.prefix(count))) }
                else if count < 0 && errno == EINTR { continue }
                else { break }
            }
            Darwin.close(readFD)
            var status: Int32 = 0
            while waitpid(spawnedPID, &status, 0) == -1 && errno == EINTR {}
            // Wait for descendants that redirected their output too.
            while kill(-spawnedPID, 0) == 0 { usleep(100_000) }
            let exitCode: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
            DispatchQueue.main.async {
                batch.flush()
                guard run.generation == generation else { return }
                run.processID = 0
                run.endedAt = Date()
                let wasStopped = run.status == .stopping
                run.status = wasStopped ? .idle : .exited(exitCode)
                if !wasStopped, exitCode != 0, project.runConfiguration?.restartPolicy == .onFailure,
                   run.restartAttempts < 3, !self.shuttingDown {
                    run.restartAttempts += 1
                    self.scheduleRestart(run, project: run.project ?? project, workspaceURL: workspaceURL, environment: overrides)
                }
                run.append(wasStopped ? "\nProceso detenido.\n" : "\nProceso finalizado (\(exitCode)).\n")
            }
        }
    }

    private func scheduleRestart(_ run: ProjectRun, project: CodeProject, workspaceURL: URL,
                                 environment: [String: String]) {
        let generation = run.generation
        run.pendingRestart = true
        Task { @MainActor [weak self, weak run] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, let run, run.pendingRestart, run.generation == generation, !self.shuttingDown else { return }
            self.start(project, workspaceURL: workspaceURL, environment: environment)
        }
    }

    func restart(_ run: ProjectRun, project: CodeProject) {
        guard let url = run.workspaceURL else { return }
        stop(run.id)
        let generation = run.generation
        run.pendingRestart = true
        Task { @MainActor [weak self, weak run] in
            guard let self, let run else { return }
            while run.status.active {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                guard run.pendingRestart, run.generation == generation, !self.shuttingDown else { return }
            }
            guard run.pendingRestart, run.generation == generation, !self.shuttingDown else { return }
            run.restartAttempts = 0
            self.start(project, workspaceURL: url)
        }
    }

    func stop(_ id: UUID, automaticallyForce: Bool = true) {
        guard let run = runs[id] else { return }
        run.pendingRestart = false
        guard run.status.active, run.processID > 0 else { return }
        run.status = .stopping
        let pid = run.processID
        let generation = run.generation
        run.stopGeneration = UUID()
        let stopGeneration = run.stopGeneration
        kill(-pid, SIGTERM)
        guard automaticallyForce else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak run] in
            guard let run, run.generation == generation, run.processID == pid,
                  run.stopGeneration == stopGeneration else { return }
            kill(-pid, SIGKILL)
        }
    }

    func forceStop(_ id: UUID) {
        guard let run = runs[id], run.status.active, run.processID > 0 else { return }
        run.status = .stopping
        kill(-run.processID, SIGKILL)
    }

    func stopAll() { for id in runs.keys { stop(id) } }

    func terminateImmediately() {
        shuttingDown = true
        for run in runs.values { run.pendingRestart = false }
        for run in runs.values where run.processID > 0 { kill(-run.processID, SIGKILL) }
    }
}
