import Darwin
import Foundation

enum CodexExecutable {
    static func locate(override: String? = nil) -> URL? {
        let paths = [override,
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/Applications/Codex.app/Contents/Resources/codex"]
        let search = paths.compactMap { $0 } + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/codex" }
        return search.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }
}

/// One child process, JSONL pipes, no sockets and no periodic polling.
/// Parsing runs off the main thread; callbacks retain their original wire order.
@MainActor final class CodexTransport {
    var onMessage: ((RPCMessage) -> Void)?
    var onDisconnect: ((String) -> Void)?
    private var processID: pid_t = 0
    private var input: FileHandle?
    private var nextID = 0
    private var generation = UUID()
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var deadlines: [Int: Task<Void, Never>] = [:]
    var running: Bool { processID > 0 }

    func start(executable: URL, arguments: [String] = ["app-server", "--listen", "stdio://"], environment: [String: String]? = nil) throws {
        guard !running else { return }
        var stdinFD: [Int32] = [0, 0], stdoutFD: [Int32] = [0, 0]
        guard pipe(&stdinFD) == 0 else { throw AgentFailure("No se pudo iniciar Codex.") }
        guard pipe(&stdoutFD) == 0 else { stdinFD.forEach { Darwin.close($0) }; throw AgentFailure("No se pudo abrir la salida de Codex.") }
        let allFD = stdinFD + stdoutFD
        allFD.forEach { _ = fcntl($0, F_SETFD, FD_CLOEXEC) }
        _ = fcntl(stdinFD[1], F_SETNOSIGPIPE, 1)
        var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions); posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        posix_spawn_file_actions_adddup2(&actions, stdinFD[0], STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, stdoutFD[1], STDOUT_FILENO)
        // Diagnostics can contain private paths. Protocol errors reach the UI; raw stderr is not stored.
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
        allFD.forEach { posix_spawn_file_actions_addclose(&actions, $0) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)
        var env = environment ?? ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        env["NO_COLOR"] = "1"
        // A host application's API key must never silently replace the requested subscription.
        env.removeValue(forKey: "OPENAI_API_KEY")
        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let envp = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, executable.path, &actions, &attributes, argv, envp)
        Darwin.close(stdinFD[0]); Darwin.close(stdoutFD[1])
        guard status == 0 else {
            Darwin.close(stdinFD[1]); Darwin.close(stdoutFD[0])
            throw AgentFailure("No se pudo iniciar Codex: \(String(cString: strerror(status))).")
        }
        let spawnedPID = pid
        processID = spawnedPID; generation = UUID()
        let token = generation, readFD = stdoutFD[0]
        input = FileHandle(fileDescriptor: stdinFD[1], closeOnDealloc: true)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var framer = JSONLineFramer(), buffer = [UInt8](repeating: 0, count: 32_768)
            var failure = "Codex se desconectó."
            do {
                while true {
                    let count = Darwin.read(readFD, &buffer, buffer.count)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { break }
                    let messages = try framer.append(Data(buffer.prefix(count))).map { try JSONDecoder().decode(RPCMessage.self, from: $0) }
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.generation == token else { return }
                        for message in messages { self.receive(message) }
                    }
                }
            } catch { failure = "Respuesta no válida de Codex: \(error.localizedDescription)" }
            Darwin.close(readFD)
            let reason = failure
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token else { return }
                self.stop(reason: reason)
                self.onDisconnect?(reason)
            }
        }
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            while waitpid(spawnedPID, &status, 0) < 0 && errno == EINTR {}
        }
    }

    func request(_ method: String, _ params: JSONValue = .object([:]), timeout: Double = 45) async throws -> JSONValue {
        try Task.checkCancellation()
        guard running else { throw AgentFailure("Codex no está conectado.") }
        nextID += 1; let id = nextID
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                do {
                    try write(RPCMessage(id: .number(Double(id)), method: method, params: params))
                    deadlines[id] = Task { [weak self] in
                        do { try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)) } catch { return }
                        self?.finish(id, .failure(AgentFailure("Codex no respondió a tiempo (\(method)).")))
                    }
                } catch { finish(id, .failure(error)) }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.finish(id, .failure(CancellationError())) } }
    }

    func notify(_ method: String) throws { try write(RPCMessage(method: method, params: .object([:]))) }
    func respond(id: JSONValue, result: JSONValue) throws { try write(RPCMessage(id: id, result: result)) }
    func reject(id: JSONValue) throws {
        try write(RPCMessage(id: id, error: .object(["code": .number(-32601), "message": .string("Este cliente no admite esta solicitud.")])))
    }

    private func write(_ message: RPCMessage) throws {
        guard let input else { throw AgentFailure("Codex no está conectado.") }
        var data = try JSONEncoder().encode(message); data.append(10)
        // Requests are bounded (the prompt is capped by the controller), not file uploads.
        try input.write(contentsOf: data)
    }
    private func receive(_ message: RPCMessage) {
        if message.method == nil, let id = message.id?.int {
            if let error = message.error { finish(id, .failure(AgentFailure(error["message"].string ?? "Error de Codex."))) }
            else { finish(id, .success(message.result ?? .null)) }
        } else { onMessage?(message) }
    }
    private func finish(_ id: Int, _ result: Result<JSONValue, Error>) {
        deadlines.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(with: result)
    }
    func stop(reason: String = "Conexión cerrada.") {
        generation = UUID()
        let pid = processID; processID = 0
        try? input?.close(); input = nil
        for id in Array(pending.keys) { finish(id, .failure(AgentFailure(reason))) }
        if pid > 0 {
            kill(-pid, SIGTERM)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
                // Process-group IDs cannot be reused while descendants remain in that group.
                if kill(-pid, 0) == 0 { kill(-pid, SIGKILL) }
            }
        }
    }
    deinit { if processID > 0 { kill(-processID, SIGTERM) } }
}
