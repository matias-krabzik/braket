import AppKit
import Observation

struct CodexModelChoice: Identifiable, Equatable {
    let id: String
    let name: String
}

/// Dueño de la conversación con Codex: el estado que ve el panel y el protocolo.
///
/// Habla por `CodexTransport` (un proceso hijo, JSONL por tuberías) y traduce sus
/// mensajes a estado observable. Tres cosas que no son obvias:
///
/// - **nada se lanza sin aprobación**: el ejecutable se le muestra al usuario con su
///   firma y su hash antes del primer arranque (S2);
/// - **todo lo que viene del modelo pasa por `ModelText`** antes de llegar al estado:
///   es contenido de terceros y no puede hacerse pasar por interfaz de la app (S5);
/// - `generation` y `operationID` descartan lo que llegue tarde de un turno anterior.
///
/// Confinado al main actor.
@MainActor @Observable
final class AgentController {
    var visible = false
    var tabOpen = false
    private(set) var sessions: [AgentSessionRecord] = []
    private(set) var selectedSessionID: UUID?
    private(set) var isLoadingSession = false
    @ObservationIgnored private var workspaceURL: URL?
    @ObservationIgnored var contextProvider: ((AgentScope) -> String)?
    @ObservationIgnored var scopeProvider: (() throws -> AgentScope)?
    @ObservationIgnored private var sessionTask: Task<Void, Never>?

    var selectedSession: AgentSessionRecord? { sessions.first { $0.id == selectedSessionID } }
    var sessionTitle: String { selectedSession?.title ?? "Codex" }
    var isBusy: Bool { isRunning || isLoadingSession }
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
    var availableModels: [CodexModelChoice] = []
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
    @ObservationIgnored private var allowedCommandTurnID: String?
    @ObservationIgnored private var scope: AgentScope?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var connectionGeneration = UUID()
    @ObservationIgnored private var operationID = UUID()
    @ObservationIgnored private var loginID: String?
    @ObservationIgnored private var sendTask: Task<Void, Never>?
    @ObservationIgnored private var commentaryIDs: Set<String> = []
    @ObservationIgnored private var proposedChanges: [String: [AgentFileChange]] = [:]
    @ObservationIgnored var executableSearch: @Sendable (String?, [URL]) ->
        (candidates: [CodexCandidate], rejected: [CodexRejection]) = { override, roots in
            CodexExecutable.search(override: override, excludedRoots: roots)
        }

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
            // Signature validation and hashing can take seconds. They must never
            // occupy MainActor, even though connect() itself updates UI state.
            let override = defaults.string(forKey: "codexExecutable")
            let roots = excludedRoots
            let searchExecutable = executableSearch
            let search = await Task.detached(priority: .utility) {
                searchExecutable(override, roots)
            }.value
            guard token == connectionGeneration else { return }
            try Task.checkCancellation()
            guard let candidate = search.candidates.first else {
                missingExecutable = true
                let descartes = search.rejected.map { "\($0.path): \($0.reason)" }.joined(separator: "; ")
                throw AgentFailure(descartes.isEmpty
                                   ? "No se encontró Codex en esta Mac."
                                   : "No se encontró un Codex utilizable. Descartados: \(descartes)")
            }
            // Sin aprobación no se lanza nada: el binario corre con el entorno completo
            // del usuario, así que el usuario tiene que ver cuál es.
            guard isApproved(candidate) else {
                pendingCandidate = candidate
                return
            }
            pendingCandidate = nil
            try transport.start(executable: candidate.url)
            _ = try await transport.request("initialize", .object([
                "clientInfo": .object(["name": .string("braket"), "title": .string("Braket"),
                                       "version": .string(Self.clientVersion)]),
                "capabilities": .object(["experimentalApi": .bool(true), "optOutNotificationMethods": .array([
                    .string("item/reasoning/textDelta"),
                    .string("item/reasoning/summaryTextDelta"),
                    .string("item/commandExecution/outputDelta")
                ])])
            ]))
            guard token == connectionGeneration else { return }
            try transport.notify("initialized")
            try await readAccount()
            guard token == connectionGeneration else { return }
            try Task.checkCancellation()
            connected = true
            await loadModels()
            await restoreSelectedSession()
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
            } catch {
                self.error = error.localizedDescription
                loginPending = false
            }
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

    static func approvalMatches(_ candidate: CodexCandidate, approved: BinaryIdentity?,
                                team: String?) -> Bool {
        guard let approved else { return false }
        if approved == candidate.identity { return true }
        guard approved.path == candidate.identity.path, let team,
              case .developerID(let currentTeam) = candidate.signature else { return false }
        return team == currentTeam
    }

    /// Una actualización firmada del mismo ejecutable conserva la aprobación. Para
    /// binarios ad hoc o sin firma, el hash sigue siendo la única autorización.
    private func isApproved(_ candidate: CodexCandidate) -> Bool {
        guard let approved = approvedIdentity else { return false }
        let team = defaults.string(forKey: "approvedCodexTeam")
        guard Self.approvalMatches(candidate, approved: approved, team: team) else { return false }
        if approved == candidate.identity {
            // Migra aprobaciones previas solo mientras el contenido aún coincide.
            if team == nil,
               case .developerID(let team) = candidate.signature {
                defaults.set(team, forKey: "approvedCodexTeam")
            }
            return true
        }
        // Guardar la identidad nueva permite que el estado y los diagnósticos
        // representen exactamente el binario que se acaba de ejecutar.
        if let data = try? JSONEncoder().encode(candidate.identity) {
            defaults.set(data, forKey: "approvedCodexBinary")
        }
        return true
    }

    var approvedExecutableURL: URL? {
        guard connected, let approvedIdentity else { return nil }
        return CodexExecutable.search(override: defaults.string(forKey: "codexExecutable"),
                                      excludedRoots: excludedRoots).candidates
            .first { $0.identity == approvedIdentity }?.url
    }

    func loadModels() async {
        guard connected, !account.isEmpty else { return }
        do {
            var choices: [CodexModelChoice] = []
            var cursor: String?
            for _ in 0..<10 {
                var params: [String: JSONValue] = ["includeHidden": .bool(false)]
                if let cursor { params["cursor"] = .string(cursor) }
                let catalog = try await transport.request("model/list", .object(params))
                choices += catalog["data"].array.compactMap { item in
                    guard let id = item["model"].string, !id.isEmpty,
                          let name = item["displayName"].string, !item["hidden"].bool else { return nil }
                    return CodexModelChoice(id: id, name: name)
                }
                cursor = catalog["nextCursor"].string
                if cursor == nil { break }
            }
            availableModels = choices
        } catch { self.error = "No se pudo cargar la lista de modelos: \(error.localizedDescription)" }
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
        if case .developerID(let team) = candidate.signature {
            defaults.set(team, forKey: "approvedCodexTeam")
        } else {
            defaults.removeObject(forKey: "approvedCodexTeam")
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
        defaults.removeObject(forKey: "approvedCodexTeam")
        pendingCandidate = nil
        transport.stop()
        connected = false
        threadID = nil
        Task { await connect() }
    }

    func configureSessions(workspace: URL) {
        clearConversation()
        workspaceURL = workspace.standardizedFileURL
        sessions = AgentSessionStore(defaults: defaults).load(workspace)
        tabOpen = false
        visible = false
    }

    func newSession() {
        guard !isBusy else { return }
        let projectID = selectedProjectID
        clearConversation()
        let record = AgentSessionRecord(projectID: projectID)
        sessions.insert(record, at: 0)
        selectedSessionID = record.id
        persistSessions()
    }

    func selectSession(_ id: UUID) {
        guard !isBusy, id != selectedSessionID,
              let record = sessions.first(where: { $0.id == id }) else { return }
        clearConversation()
        selectedSessionID = id
        selectedProjectID = record.projectID
        draft = record.draft
        if connected {
            sessionTask = Task { await restoreSelectedSession() }
        }
    }

    func renameSession(_ id: UUID, title: String) {
        let title = ModelText.display(title.trimmingCharacters(in: .whitespacesAndNewlines), limit: 100)
        guard !title.isEmpty, let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].title = title
        persistSessions()
    }

    private func persistSessions() {
        guard let workspaceURL else { return }
        AgentSessionStore(defaults: defaults).save(sessions, workspace: workspaceURL)
    }

    private func updateSession(_ update: (inout AgentSessionRecord) -> Void) {
        guard let index = sessions.firstIndex(where: { $0.id == selectedSessionID }) else { return }
        update(&sessions[index])
        persistSessions()
    }

    private func saveDraft() {
        let text = String(draft.prefix(32_000))
        let projectID = selectedProjectID
        updateSession {
            $0.draft = text
            if $0.roots.isEmpty { $0.projectID = projectID }
        }
    }

    private func threadParameters(_ scope: AgentScope) -> [String: JSONValue] {
        ["cwd": .string(scope.cwd.path), "sandbox": .string("workspace-write"),
         "approvalPolicy": .string("on-request"), "developerInstructions": .string(scope.instructions),
         "config": .object([
             "model_provider": .string("openai"), "approvals_reviewer": .string("user"),
             "features.multi_agent": .bool(false),
             "sandbox_workspace_write.writable_roots": .array(scope.roots.map { .string($0.path) }),
             "sandbox_workspace_write.network_access": .bool(false),
             "sandbox_workspace_write.exclude_slash_tmp": .bool(true),
             "sandbox_workspace_write.exclude_tmpdir_env_var": .bool(true)
         ])]
    }

    private func restoreSelectedSession() async {
        guard connected, !account.isEmpty, threadID == nil, !isBusy,
              let record = selectedSession, let savedID = record.threadID else { return }
        let token = generation
        isLoadingSession = true
        error = nil
        defer { if token == generation { isLoadingSession = false } }
        do {
            guard let scopeProvider else { throw AgentFailure("No hay un proyecto disponible para esta sesión.") }
            let currentScope = try scopeProvider()
            guard currentScope.roots == record.roots else {
                throw AgentFailure("Las carpetas de esta sesión cambiaron. Creá una nueva sesión para el alcance actual.")
            }
            var params = threadParameters(currentScope)
            params["threadId"] = .string(savedID)
            params["excludeTurns"] = .bool(true)
            let response = try await transport.request("thread/resume", .object(params), timeout: 30)
            guard token == generation, !Task.isCancelled else { return }
            var turns = response["thread"]["turns"].array
            if turns.isEmpty {
                do {
                    let history = try await transport.request("thread/turns/list", .object([
                        "threadId": .string(savedID), "limit": .number(40),
                        "sortDirection": .string("desc"), "itemsView": .string("full")
                    ]))
                    turns = history["data"].array.reversed()
                } catch {
                    // Compatibilidad con versiones que guardaban todo el historial en thread/read.
                    let history = try await transport.request("thread/read", .object([
                        "threadId": .string(savedID), "includeTurns": .bool(true)
                    ]))
                    turns = history["thread"]["turns"].array
                }
            }
            guard token == generation, !Task.isCancelled else { return }
            threadID = savedID
            scope = currentScope
            model = response["model"].string ?? ""
            messages = Self.historyMessages(turns)
            trimHistory()
        } catch {
            guard token == generation, !Task.isCancelled else { return }
            self.error = "No se pudo recuperar la sesión: \(error.localizedDescription)"
        }
    }

    static func historyMessages(_ turns: [JSONValue]) -> [AgentMessage] {
        turns.flatMap { turn in
            turn["items"].array.compactMap { item in
                guard let id = item["id"].string else { return nil }
                switch item["type"].string {
                case "userMessage":
                    let text = item["content"].array.compactMap { content -> String? in
                        guard content["type"].string == "text", let text = content["text"].string,
                              !text.hasPrefix(AgentContext.marker) else { return nil }
                        return text
                    }.joined(separator: "\n")
                    return AgentMessage(id: id, isUser: true, text: ModelText.display(text, limit: 32_000))
                case "agentMessage":
                    guard item["phase"].string != "commentary" else { return nil }
                    return AgentMessage(id: id, isUser: false, text: ModelText.display(item["text"].string ?? "", limit: 120_000))
                default: return nil
                }
            }
        }
    }

    func send(_ prompt: String, scope newScope: AgentScope, context: String = "") {
        guard !isBusy, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard prompt.utf8.count <= 32_000 else {
            error = "El mensaje admite hasta 32 KB."
            return
        }
        guard connected, !account.isEmpty else {
            error = "Conectá tu cuenta de ChatGPT."
            return
        }
        if let saved = selectedSession, !saved.roots.isEmpty, saved.roots != newScope.roots {
            error = "Las carpetas de esta sesión cambiaron. Creá una nueva sesión para trabajar con el alcance actual."
            return
        }
        if selectedSessionID == nil { newSession() }
        scope = newScope
        updateSession { session in
            if session.threadID == nil && session.title == "Nueva sesión" {
                session.title = ModelText.display(prompt, limit: 70).replacingOccurrences(of: "\n", with: " ")
            }
            session.roots = newScope.roots
            session.projectID = selectedProjectID
            session.draft = ""
            session.updatedAt = Date()
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
                    var params = threadParameters(newScope)
                    let method: String
                    if let savedID = selectedSession?.threadID {
                        method = "thread/resume"
                        params["threadId"] = .string(savedID)
                        params["excludeTurns"] = .bool(true)
                    } else {
                        method = "thread/start"
                        params["ephemeral"] = .bool(false)
                        params["dynamicTools"] = .array([AgentContext.tool])
                    }
                    let result = try await transport.request(method, .object(params), timeout: 90)
                    guard token == generation, operation == operationID, !Task.isCancelled else { return }
                    guard let id = result["thread"]["id"].string else { throw AgentFailure("Codex no creó la conversación.") }
                    threadID = id
                    updateSession { $0.threadID = id }
                    model = result["model"].string ?? ""
                }
                guard token == generation, operation == operationID, let threadID, !Task.isCancelled else { return }
                let result = try await transport.request("turn/start", .object([
                    "threadId": .string(threadID),
                    "input": .array([prompt, context].filter { !$0.isEmpty }
                    .map { .object(["type": .string("text"), "text": .string($0)]) }),
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

    func answer(_ request: AgentRequest, accept: Bool, forSession: Bool = false,
                remainingTurn: Bool = false) {
        do {
            let result: JSONValue
            if request.isPermissions {
                result = .object(["permissions": accept ? request.params["permissions"] : .object([:]),
                                  "scope": .string(forSession ? "session" : "turn")])
            } else {
                let decision = accept ? (forSession ? "acceptForSession" : "accept") : "decline"
                result = .object(["decision": .string(decision)])
            }
            try transport.respond(id: request.rpcID, result: result)
            if accept && remainingTurn && request.method == "item/commandExecution/requestApproval" {
                allowedCommandTurnID = request.params["turnId"].string
            }
            requests.removeAll { $0.id == request.id }
        } catch { finishTurn(error: "Se perdió la conexión con Codex al responder una solicitud.") }
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
        saveDraft()
        sessionTask?.cancel()
        sessionTask = nil
        isLoadingSession = false
        selectedSessionID = nil
        scope = nil
        draft = ""
        if let threadID, transport.running {
            Task { _ = try? await transport.request("thread/unsubscribe", .object(["threadId": .string(threadID)])) }
        }
        generation = UUID()
        threadID = nil
        turnID = nil
        allowedCommandTurnID = nil
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
        saveDraft()
        sessionTask?.cancel()
        sessionTask = nil
        isLoadingSession = false
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
        allowedCommandTurnID = nil
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
        allowedCommandTurnID = nil
        requests = []
        activity = ""
        if let error { self.error = error }
        if let scope { onFilesChanged?(scope) }
        trimHistory()
        updateSession { $0.updatedAt = Date() }
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
            if let eventTurn = p["turnId"].string, let turnID, eventTurn != turnID {
                reject(id, method: method)
                return
            }
            switch method {
            case "item/commandExecution/requestApproval"
                where p["turnId"].string != nil && p["turnId"].string == allowedCommandTurnID:
                respond(id, method: method, result: .object(["decision": .string("accept")]))
            case "item/tool/call":
                guard p["tool"].string == AgentContext.toolName, let scope, let contextProvider else {
                    reject(id, method: method)
                    return
                }
                activity = "Consultando el editor y los procesos…"
                respond(id, method: method, result: .object([
                    "success": .bool(true), "contentItems": .array([
                        .object(["type": .string("inputText"), "text": .string(contextProvider(scope))])
                    ])
                ]))
            case "item/commandExecution/requestApproval", "item/fileChange/requestApproval",
                 "item/tool/requestUserInput", "item/permissions/requestApproval":
                let request = AgentRequest(id: id.pretty, rpcID: id, method: method, params: p)
                requests.append(request)
                // Una pregunta con riesgo de secreto se registra sin su contenido: si pasa
                // de verdad hay que poder reconstruir que se pidió, no qué decía.
                if request.isSecret {
                    Log.agent.notice("solicitud marcada como secreta en \(method, privacy: .public)")
                }
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
        case "turn/completed": finishTurn(from: p["turn"])
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
            handle(item: p["item"], completed: method == "item/completed")
        default: break
        }
    }

    /// Fin de turno. El estado decide si fue un fallo, una interrupción o un final normal;
    /// el mensaje de error viene del modelo, así que pasa por `ModelText`.
    private func finishTurn(from turn: JSONValue) {
        guard turnID == nil || turn["id"].string == turnID else { return }
        let status = turn["status"].string
        let failure = ModelText.display(turn["error"]["message"].string ?? "La tarea falló.", limit: 2_000)
        finishTurn(error: status == "failed" ? failure
            : status == "interrupted" ? "Tarea detenida. Los cambios realizados se conservaron."
            : nil)
    }

    /// Un ítem del turno, empezado o terminado. El mismo evento llega dos veces —una al
    /// empezar y otra al terminar— y `completed` es lo que distingue qué hacer: al empezar
    /// se muestra actividad, al terminar se guarda el resultado.
    private func handle(item: JSONValue, completed: Bool) {
        guard let id = item["id"].string else { return }
        switch item["type"].string {
        case "agentMessage":
            handle(message: item, id: id, completed: completed)
        case "commandExecution":
            if !completed {
                activity = ModelText.display(item["command"].string ?? "Ejecutando…", limit: 180)
            }
        case "fileChange":
            handle(fileChange: item, id: id, completed: completed)
        default:
            break
        }
    }

    /// Un mensaje del modelo. Los de fase `commentary` no son respuesta: son el relato de
    /// lo que está haciendo, y van a `activity` en vez de a la conversación.
    private func handle(message item: JSONValue, id: String, completed: Bool) {
        if item["phase"].string == "commentary" {
            commentaryIDs.insert(id)
            if completed { activity = ModelText.display(item["text"].string ?? "Trabajando…", limit: 160) }
        } else if completed {
            agentMessage(id).text = ModelText.display(item["text"].string ?? "", limit: 120_000)
        }
    }

    /// Archivos que el modelo propone o ya cambió. Mientras el ítem no está completo los
    /// cambios quedan en `proposedChanges`, que es lo que el diálogo de aprobación muestra;
    /// al completarse pasan a `changes` y se avisa para refrescar el árbol.
    private func handle(fileChange item: JSONValue, id: String, completed: Bool) {
        let files = item["changes"].array.compactMap { value -> AgentFileChange? in
            guard let path = value["kind"]["move_path"].string ?? value["path"].string else { return nil }
            return AgentFileChange(path: ModelText.display(path, limit: 1_024),
                                   kind: value["kind"]["type"].string ?? "update",
                                   diff: ModelText.display(value["diff"].string ?? "", limit: 100_000))
        }
        if completed { proposedChanges.removeValue(forKey: id) }
        else { proposedChanges[id] = files }
        guard completed, item["status"].string == "completed" else {
            if !completed { activity = "Editando archivos…" }
            return
        }
        for file in files {
            if let index = changes.firstIndex(where: { $0.path == file.path }) { changes[index] = file }
            else if changes.count < 500 { changes.append(file) }
        }
        if let scope { onFilesChanged?(scope) }
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
