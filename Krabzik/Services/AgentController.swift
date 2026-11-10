import AppKit
import Observation

@MainActor @Observable
final class AgentController {
    var visible = false
    var selectedProjectID: UUID?
    var draft = ""
    var messages: [AgentMessage] = []
    var changes: [AgentFileChange] = []
    var requests: [AgentRequest] = []
    var diff = ""
    var error: String?
    var activity = ""
    var account = ""
    var model = ""
    var isConnecting = false
    var isRunning = false
    var isStopping = false
    var loginPending = false
    var connected = false
    var missingExecutable = false
    /// Candidato encontrado que el usuario todavía no aprobó. Mientras esté puesto,
    /// NO se lanza ningún proceso. Ver docs/specs/S2-verificar-ejecutable-codex.md.
    var pendingCandidate: CodexCandidate?
    /// Raíces del proyecto abierto: un repositorio no puede aportar su propio `codex`.
    @ObservationIgnored var excludedRoots: [URL] = []
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored let transport = CodexTransport()
    @ObservationIgnored var onFilesChanged: ((AgentScope) -> Void)?
    @ObservationIgnored private var threadID: String?
    @ObservationIgnored private var turnID: String?
    @ObservationIgnored private var scope: AgentScope?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var connectionGeneration = UUID()
    @ObservationIgnored private var operationID = UUID()
    @ObservationIgnored private var loginID: String?
    @ObservationIgnored private var sendTask: Task<Void, Never>?
    @ObservationIgnored private var commentaryIDs: Set<String> = []
    @ObservationIgnored private var proposedChanges: [String: [AgentFileChange]] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        transport.onMessage = { [weak self] in self?.receive($0) }
        transport.onDisconnect = { [weak self] reason in
            guard let self else { return }
            self.connected = false
            self.account = ""
            self.isConnecting = false
            self.loginPending = false
            self.threadID = nil
            if self.isRunning { self.finishTurn(error: reason) }
            else { self.error = reason }
        }
    }

    /// La versión que la app declara a Codex. Sale del bundle, que la toma de
    /// MARKETING_VERSION: no se repite el número en el código.
    static var clientVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    func connect() async {
        guard !isConnecting else { return }
        if connected && transport.running { return }
        isConnecting = true
        error = nil
        missingExecutable = false
        let token = connectionGeneration
        defer { if token == connectionGeneration { isConnecting = false } }
        do {
            let search = CodexExecutable.search(override: defaults.string(forKey: "codexExecutable"),
                                                excludedRoots: excludedRoots)
            guard let candidate = search.candidates.first else {
                missingExecutable = true
                let descartes = search.rejected.map { "\($0.path): \($0.reason)" }.joined(separator: "; ")
                throw AgentFailure(descartes.isEmpty
                                   ? "No se encontró Codex en esta Mac."
                                   : "No se encontró un Codex utilizable. Descartados: \(descartes)")
            }
            // Sin aprobación no se lanza nada: el binario corre con el entorno completo
            // del usuario, así que el usuario tiene que ver cuál es.
            guard approvedIdentity == candidate.identity else {
                pendingCandidate = candidate
                return
            }
            pendingCandidate = nil
            try transport.start(executable: candidate.url)
            _ = try await transport.request("initialize", .object([
                "clientInfo": .object(["name": .string("krabzik_ide"), "title": .string("Krabzik IDE"),
                                       "version": .string(Self.clientVersion)]),
                "capabilities": .object(["optOutNotificationMethods": .array([
                    .string("item/reasoning/textDelta"),
                    .string("item/reasoning/summaryTextDelta"),
                    .string("item/commandExecution/outputDelta")
                ])])
            ]))
            guard token == connectionGeneration else { return }
            try transport.notify("initialized")
            connected = true
            try await readAccount()
        } catch {
            guard token == connectionGeneration else { return }
            self.error = error.localizedDescription
            connected = false
            transport.stop()
            threadID = nil
        }
    }

    private func readAccount() async throws {
        let response = try await transport.request("account/read", .object(["refreshToken": .bool(false)]))
        let value = response["account"]
        if value["type"].string == "chatgpt" {
            let plan = value["planType"].string ?? ""
            account = "ChatGPT" + (plan.isEmpty || plan == "unknown" ? "" : " · \(plan.capitalized)")
        } else { account = "" }
    }

    func login() {
        guard !loginPending else { return }
        Task {
            if !connected { await connect() }
            guard connected else { return }
            loginPending = true
            error = nil
            do {
                let result = try await transport.request("account/login/start", .object(["type": .string("chatgpt")]))
                loginID = result["loginId"].string
                guard let text = result["authUrl"].string, let url = URL(string: text),
                      url.scheme == "https", let host = url.host,
                      host == "auth.openai.com" || host == "chatgpt.com" || host.hasSuffix(".chatgpt.com") else {
                    throw AgentFailure("Codex no devolvió una dirección de inicio de sesión válida.")
                }
                guard NSWorkspace.shared.open(url) else { throw AgentFailure("No se pudo abrir el navegador.") }
            } catch { self.error = error.localizedDescription
            loginPending = false }
        }
    }

    func cancelLogin() {
        if let loginID {
            Task { _ = try? await transport.request("account/login/cancel", .object(["loginId": .string(loginID)])) }
        }
        loginPending = false
        loginID = nil
    }

    /// Diagnóstico del último arranque de Codex: su stderr, en memoria. Vacío si no dijo
    /// nada. Se muestra bajo demanda y no se guarda en ninguna parte.
    var diagnostics: String { transport.diagnostics }

    /// Identidad del binario que el usuario aprobó, si hay alguna.
    var approvedIdentity: BinaryIdentity? {
        guard let data = defaults.data(forKey: "approvedCodexBinary") else { return nil }
        return try? JSONDecoder().decode(BinaryIdentity.self, from: data)
    }

    /// `true` si el candidato pendiente reemplaza a uno aprobado antes: el diálogo
    /// tiene que decir "el ejecutable cambió", no el texto de primera aprobación.
    var replacesApprovedBinary: Bool {
        guard let approved = approvedIdentity, let pending = pendingCandidate else { return false }
        return approved != pending.identity
    }

    func approve(_ candidate: CodexCandidate) {
        if let data = try? JSONEncoder().encode(candidate.identity) {
            defaults.set(data, forKey: "approvedCodexBinary")
        }
        pendingCandidate = nil
        Task { await connect() }
    }

    func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "Seleccionar Codex"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            error = "Seleccioná el ejecutable de Codex."
            return
        }
        defaults.set(url.path, forKey: "codexExecutable")
        // Elegir un ejecutable no lo aprueba: se vuelve a pedir confirmación.
        defaults.removeObject(forKey: "approvedCodexBinary")
        pendingCandidate = nil
        transport.stop()
        connected = false
        threadID = nil
        Task { await connect() }
    }

    func send(_ prompt: String, scope newScope: AgentScope) {
        guard !isRunning, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard prompt.utf8.count <= 32_000 else {
            error = "El mensaje admite hasta 32 KB."
            return
        }
        guard connected, !account.isEmpty else {
            error = "Conectá tu cuenta de ChatGPT."
            return
        }
        if scope != newScope {
            clearConversation()
            scope = newScope
        }
        let token = generation
        operationID = UUID()
        let operation = operationID
        isRunning = true
        isStopping = false
        error = nil
        changes = []
        diff = ""
        requests = []
        proposedChanges = [:]
        commentaryIDs = []
        activity = "Preparando…"
        messages.append(AgentMessage(isUser: true, text: prompt))
        trimHistory()
        draft = ""
        sendTask = Task {
            do {
                if threadID == nil {
                    let result = try await transport.request("thread/start", .object([
                        "cwd": .string(newScope.cwd.path), "sandbox": .string("workspace-write"),
                        "approvalPolicy": .string("on-request"), "ephemeral": .bool(true),
                        "developerInstructions": .string(newScope.instructions),
                        "config": .object([
                            "model_provider": .string("openai"),
                            "approvals_reviewer": .string("user"), "features.multi_agent": .bool(false),
                            "sandbox_workspace_write.writable_roots": .array(newScope.roots.map { .string($0.path) }),
                            "sandbox_workspace_write.network_access": .bool(false),
                            "sandbox_workspace_write.exclude_slash_tmp": .bool(true),
                            "sandbox_workspace_write.exclude_tmpdir_env_var": .bool(true)
                        ])
                    ]), timeout: 90)
                    guard token == generation, operation == operationID, !Task.isCancelled else { return }
                    guard let id = result["thread"]["id"].string else { throw AgentFailure("Codex no creó la conversación.") }
                    threadID = id
                    model = result["model"].string ?? ""
                }
                guard token == generation, operation == operationID, let threadID, !Task.isCancelled else { return }
                let result = try await transport.request("turn/start", .object([
                    "threadId": .string(threadID), "input": .array([.object(["type": .string("text"), "text": .string(prompt)])]),
                    "cwd": .string(newScope.cwd.path), "approvalPolicy": .string("on-request"), "sandboxPolicy": newScope.sandbox
                ]), timeout: 90)
                guard token == generation, operation == operationID, isRunning else { return }
                turnID = result["turn"]["id"].string
                activity = "Trabajando…"
                if isStopping { await interrupt() }
            } catch {
                guard token == generation, operation == operationID else { return }
                // A timed-out start may still reach the server. Close it so it cannot edit later.
                transport.stop()
                connected = false
                threadID = nil
                finishTurn(error: error is CancellationError ? "Tarea cancelada." : error.localizedDescription)
            }
        }
    }

    func stop() {
        guard isRunning, !isStopping else { return }
        isStopping = true
        activity = "Deteniendo…"
        Task { await interrupt() }
    }

    private func interrupt() async {
        let token = generation
        let operation = operationID
        if let threadID, let turnID {
            do {
                _ = try await transport.request("turn/interrupt", .object(["threadId": .string(threadID), "turnId": .string(turnID)]),
                                                timeout: 5)
                // A response acknowledges interruption; completion is a separate notification.
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            } catch {
                // El interrupt no llegó. El turno se corta igual más abajo, pero sin esto
                // no habría forma de saber que el modelo nunca se enteró.
                Log.agent.error("turn/interrupt falló: \(error.localizedDescription, privacy: .private)")
            }
        }
        if token == generation, operation == operationID, isRunning {
            sendTask?.cancel()
            transport.stop()
            connected = false
            threadID = nil
            finishTurn(error: "Tarea detenida. Los cambios realizados se conservaron.")
        }
    }

    func answer(_ request: AgentRequest, accept: Bool) {
        do {
            try transport.respond(id: request.rpcID, result: .object(["decision": .string(accept ? "accept" : "decline")]))
            requests.removeAll { $0.id == request.id }
        } catch { self.error = error.localizedDescription }
    }

    func answerQuestions(_ request: AgentRequest, answers: [String: String]) {
        let values = answers.mapValues { JSONValue.object(["answers": .array([.string($0)])]) }
        do {
            try transport.respond(id: request.rpcID, result: .object(["answers": .object(values)]))
            requests.removeAll { $0.id == request.id }
        } catch { self.error = error.localizedDescription }
    }

    func clearConversation() {
        guard !isRunning else { return }
        if let threadID, transport.running {
            Task { _ = try? await transport.request("thread/unsubscribe", .object(["threadId": .string(threadID)])) }
        }
        generation = UUID()
        threadID = nil
        turnID = nil
        messages = []
        changes = []
        diff = ""
        requests = []
        error = nil
        model = ""
        proposedChanges = [:]
        commentaryIDs = []
    }

    func shutdown() {
        connectionGeneration = UUID()
        generation = UUID()
        sendTask?.cancel()
        sendTask = nil
        transport.stop()
        connected = false
        account = ""
        isConnecting = false
        loginPending = false
        loginID = nil
        if isRunning, let scope { onFilesChanged?(scope) }
        isRunning = false
        isStopping = false
        turnID = nil
        threadID = nil
        requests = []
        activity = ""
    }

    /// Responder a una solicitud del modelo no puede fallar en silencio: si el canal de
    /// escritura está roto, el turno queda esperando algo que no va a llegar.
    private func respond(_ id: JSONValue, method: String, result: JSONValue) {
        do {
            try transport.respond(id: id, result: result)
        } catch {
            Log.agent.error("sin poder responder a \(method, privacy: .public): \(error.localizedDescription, privacy: .private)")
            finishTurn(error: "Se perdió la conexión con Codex al responder una solicitud.")
        }
    }

    private func reject(_ id: JSONValue, method: String) {
        do {
            try transport.reject(id: id)
        } catch {
            Log.agent.error("sin poder rechazar \(method, privacy: .public): \(error.localizedDescription, privacy: .private)")
            finishTurn(error: "Se perdió la conexión con Codex al responder una solicitud.")
        }
    }

    private func finishTurn(error: String?) {
        operationID = UUID()
        isRunning = false
        isStopping = false
        turnID = nil
        requests = []
        activity = ""
        if let error { self.error = error }
        if let scope { onFilesChanged?(scope) }
        trimHistory()
    }

    private func trimHistory() {
        while messages.count > 80 || (messages.count > 2 && messages.reduce(0, { $0 + $1.text.utf8.count }) > 500_000) {
            messages.removeFirst()
        }
    }

    // Internal for deterministic protocol-fixture tests. No model output is executed here.
    func receive(_ message: RPCMessage) {
        guard let method = message.method else { return }
        let p = message.params ?? .null
        if method == "account/login/completed" {
            loginPending = false
            loginID = nil
            if p["success"].bool { Task { do { try await readAccount() } catch { self.error = error.localizedDescription } } }
            else { error = p["error"].string ?? "No se completó el inicio de sesión." }
            return
        }
        if method == "account/updated" {
            Task {
                do {
                    try await readAccount()
                } catch {
                    Log.agent.error("account/updated sin poder releer la cuenta: \(error.localizedDescription, privacy: .private)")
                }
            }
            return
        }
        if let id = message.id {
            guard isRunning, p["threadId"].string == threadID else {
                reject(id, method: method)
                return
            }
            switch method {
            case "item/commandExecution/requestApproval", "item/fileChange/requestApproval", "item/tool/requestUserInput":
                let request = AgentRequest(id: id.pretty, rpcID: id, method: method, params: p)
                requests.append(request)
                // Una pregunta con riesgo de secreto se registra sin su contenido: si pasa
                // de verdad hay que poder reconstruir que se pidió, no qué decía.
                if request.isSecret {
                    Log.agent.notice("solicitud marcada como secreta en \(method, privacy: .public)")
                }
            case "item/permissions/requestApproval":
                respond(id, method: method,
                        result: .object(["permissions": .object([:]), "scope": .string("turn")]))
            case "mcpServer/elicitation/request":
                respond(id, method: method, result: .object(["action": .string("cancel")]))
            default: reject(id, method: method)
            }
            return
        }
        guard isRunning, p["threadId"].string == threadID else { return }
        if let eventTurn = p["turnId"].string, let turnID, eventTurn != turnID { return }
        switch method {
        case "turn/started": turnID = p["turn"]["id"].string
        case "turn/completed":
            let turn = p["turn"]
            guard turnID == nil || turn["id"].string == turnID else { return }
            let status = turn["status"].string
            let failure = ModelText.display(turn["error"]["message"].string ?? "La tarea falló.", limit: 2_000)
            finishTurn(error: status == "failed" ? failure
                              : status == "interrupted" ? "Tarea detenida. Los cambios realizados se conservaron."
                              : nil)
        case "error":
            if !p["willRetry"].bool {
                error = ModelText.display(p["error"]["message"].string ?? "Error de Codex.", limit: 2_000)
            }
        case "turn/diff/updated": diff = ModelText.display(p["diff"].string ?? "", limit: 200_000)
        case "serverRequest/resolved": requests.removeAll { $0.rpcID == p["requestId"] }
        case "item/agentMessage/delta":
            guard let id = p["itemId"].string, !commentaryIDs.contains(id) else { return }
            let message = agentMessage(id)
            if message.text.utf8.count < 120_000 {
                message.text += ModelText.display(p["delta"].string ?? "", limit: 4_000)
            }
        case "item/started", "item/completed":
            let item = p["item"], completed = method == "item/completed"
            guard let id = item["id"].string else { return }
            switch item["type"].string {
            case "agentMessage":
                if item["phase"].string == "commentary" {
                    commentaryIDs.insert(id)
                    if completed { activity = ModelText.display(item["text"].string ?? "Trabajando…", limit: 160) }
                } else if completed {
                    agentMessage(id).text = ModelText.display(item["text"].string ?? "", limit: 120_000)
                }
            case "commandExecution":
                if !completed { activity = "Ejecutando…" }
            case "fileChange":
                let files = item["changes"].array.compactMap { value -> AgentFileChange? in
                    guard let path = value["kind"]["move_path"].string ?? value["path"].string else { return nil }
                    return AgentFileChange(path: ModelText.display(path, limit: 1_024),
                                           kind: value["kind"]["type"].string ?? "update",
                                           diff: ModelText.display(value["diff"].string ?? "", limit: 100_000))
                }
                if completed { proposedChanges.removeValue(forKey: id) }
                else { proposedChanges[id] = files }
                if completed, item["status"].string == "completed" {
                    for file in files {
                        if let index = changes.firstIndex(where: { $0.path == file.path }) { changes[index] = file }
                        else if changes.count < 500 { changes.append(file) }
                    }
                    if let scope { onFilesChanged?(scope) }
                } else if !completed { activity = "Editando archivos…" }
            default: break
            }
        default: break
        }
    }

    func proposedDiff(for request: AgentRequest) -> String {
        (proposedChanges[request.params["itemId"].string ?? ""] ?? []).map { $0.path + "\n" + $0.diff }.joined(separator: "\n\n")
    }
    private func agentMessage(_ id: String) -> AgentMessage {
        if let message = messages.first(where: { $0.id == id }) { return message }
        let message = AgentMessage(id: id, isUser: false, text: "")
        messages.append(message)
        return message
    }
}
