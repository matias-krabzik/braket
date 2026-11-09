import Foundation
import Observation
import Darwin

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

@MainActor @Observable
final class ProjectRun: Identifiable {
    let id: UUID
    var status: RunStatus = .idle
    var output = ""
    var revision = 0
    @ObservationIgnored var processID: pid_t = 0
    @ObservationIgnored var generation = UUID()

    init(id: UUID) { self.id = id }

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

@MainActor @Observable
final class ProcessRunner {
    var runs: [UUID: ProjectRun] = [:]
    var hasActiveProcesses: Bool { runs.values.contains { $0.status.active } }

    func state(for id: UUID) -> ProjectRun {
        if let run = runs[id] { return run }
        let run = ProjectRun(id: id)
        runs[id] = run
        return run
    }

    func start(_ project: CodeProject, workspaceURL: URL) {
        let run = state(for: project.id)
        guard !run.status.active, !project.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let directory = project.directory(relativeTo: workspaceURL)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            run.status = .failed("Carpeta no disponible")
            run.append("\nNo se encuentra \(directory.path)\n")
            return
        }
        run.generation = UUID()
        let generation = run.generation
        run.output = "$ \(project.command)\n"
        run.revision += 1

        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { run.status = .failed("No se pudo abrir la salida"); return }
        let readFD = descriptors[0], writeFD = descriptors[1]
        _ = fcntl(readFD, F_SETFD, FD_CLOEXEC)
        _ = fcntl(writeFD, F_SETFD, FD_CLOEXEC)

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
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
        let arguments = ["/bin/zsh", "-l", "-c", "cd -- \(Shell.quote(directory.path)) && \(project.command)"]
        let argv = arguments.map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, "/bin/zsh", &actions, &attributes, argv, envp)
        Darwin.close(writeFD)
        guard result == 0 else {
            Darwin.close(readFD)
            run.status = .failed(String(cString: strerror(result)))
            run.append("\(String(cString: strerror(result)))\n")
            return
        }
        let spawnedPID = pid
        run.processID = spawnedPID
        run.status = .running
        let batch = OutputBatch { [weak run] text in
            guard let run, run.generation == generation else { return }
            run.append(text)
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
            let exitCode: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
            DispatchQueue.main.async {
                batch.flush()
                guard run.generation == generation else { return }
                run.processID = 0
                let wasStopped = run.status == .stopping
                run.status = wasStopped ? .idle : .exited(exitCode)
                run.append(wasStopped ? "\nProceso detenido.\n" : "\nProceso finalizado (\(exitCode)).\n")
            }
        }
    }

    func stop(_ id: UUID) {
        guard let run = runs[id], run.status.active, run.processID > 0 else { return }
        run.status = .stopping
        let pid = run.processID
        let generation = run.generation
        kill(-pid, SIGTERM)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak run] in
            guard let run, run.generation == generation, run.processID == pid else { return }
            kill(-pid, SIGKILL)
        }
    }

    func stopAll() { for id in runs.keys { stop(id) } }

    func terminateImmediately() {
        for run in runs.values where run.processID > 0 { kill(-run.processID, SIGKILL) }
    }
}
