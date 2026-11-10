import SwiftUI

struct AgentPanel: View {
    @Bindable var controller: WorkspaceController
    @State private var showingDiff = false
    @State private var showingDiagnostics = false

    /// El stderr de Codex explica casi todos los arranques fallidos. Se muestra solo si
    /// dijo algo, y solo cuando el usuario lo pide: puede contener rutas privadas.
    @ViewBuilder private func diagnosticsButton(_ agent: AgentController) -> some View {
        if !agent.diagnostics.isEmpty {
            Button("Ver diagnóstico") { showingDiagnostics = true }
                .buttonStyle(.link).font(.system(size: 11))
        }
    }

    var body: some View {
        @Bindable var agent = controller.agent
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Codex").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(agent.account).font(.system(size: 10)).foregroundStyle(.secondary).help(agent.model)
                Button { agent.clearConversation() } label: { Image(systemName: "square.and.pencil") }
                    .disabled(agent.isRunning || agent.messages.isEmpty).help("Nueva conversación").accessibilityLabel("Nueva conversación")
                Button { agent.visible = false } label: { Image(systemName: "xmark") }
                    .help("Cerrar panel Codex").accessibilityLabel("Cerrar panel Codex")
            }.buttonStyle(.plain).padding(.horizontal, 14).frame(height: 39).background(Theme.bar)
            Divider()
            if agent.isConnecting {
                Spacer(); ProgressView().controlSize(.small); Spacer()
            } else if !agent.connected || agent.account.isEmpty {
                VStack(spacing: 14) {
                    if agent.loginPending {
                        Text("Continuá en el navegador").font(.system(size: 12)).foregroundStyle(.secondary)
                        Button("Cancelar", action: agent.cancelLogin)
                    } else if let candidate = agent.pendingCandidate {
                        approval(candidate, replaces: agent.replacesApprovedBinary, agent: agent)
                    } else if agent.missingExecutable {
                        Text(agent.error ?? "No se encontró Codex en esta Mac.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center).padding(.horizontal, 20)
                        Button("Seleccionar Codex…", action: agent.chooseExecutable)
                        diagnosticsButton(agent)
                    }
                    else if !agent.connected { Button("Conectar Codex") { Task { await agent.connect() } } }
                    else { Button("Iniciar sesión con ChatGPT", action: agent.login) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Picker("Subproyectos", selection: $agent.selectedProjectID) {
                    Text("Todos los subproyectos").tag(nil as UUID?)
                    ForEach(controller.workspace?.projects ?? []) { project in Text(project.name).tag(Optional(project.id)) }
                }.labelsHidden().pickerStyle(.menu).disabled(agent.isRunning).padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(agent.messages) { message in AgentMessageView(message: message) }
                        if agent.isRunning {
                            HStack(alignment: .top, spacing: 8) {
                                ProgressView().controlSize(.mini)
                                Text(agent.requests.isEmpty ? agent.activity : "Esperando respuesta…")
                                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.padding(14)
                }.defaultScrollAnchor(.bottom)
                if !agent.changes.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text("\(agent.changes.count) archivos modificados").font(.system(size: 10)).foregroundStyle(.secondary)
                            Spacer()
                            Button("Ver cambios") { showingDiff = true }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.blue)
                        }
                        ScrollView {
                            VStack(alignment: .leading, spacing: 5) {
                                ForEach(agent.changes) { change in
                                    Button { controller.openAgentFile(change.path) } label: {
                                        HStack(spacing: 7) {
                                            Text(change.kind == "add" ? "+" : change.kind == "delete" ? "−" : "M")
                                                .foregroundStyle(change.kind == "delete" ? Color.red : Theme.blue).font(.system(size: 10, design: .monospaced))
                                            Text(controller.agentFileLabel(change.path)).lineLimit(1).truncationMode(.middle)
                                        }.font(.system(size: 11))
                                    }.buttonStyle(.plain).disabled(change.kind == "delete").help(change.path)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(maxHeight: 100)
                    }.padding(12)
                }
                if let request = agent.requests.first { Divider(); AgentRequestView(request: request, agent: agent).id(request.id).padding(12) }
                Divider()
                VStack(spacing: 8) {
                    AgentComposer(text: $agent.draft, enabled: !agent.isRunning, send: controller.sendToAgent).frame(height: 82)
                        .overlay(alignment: .topLeading) {
                            if agent.draft.isEmpty { Text("Pedile un cambio a Codex…").font(.system(size: 12)).foregroundStyle(.tertiary).padding(5).allowsHitTesting(false) }
                        }
                    HStack {
                        Spacer()
                        if agent.isRunning {
                            Button(action: agent.stop) { Image(systemName: "stop.fill") }
                                .disabled(agent.isStopping).help("Detener Codex").accessibilityLabel("Detener Codex")
                        } else {
                            Button(action: controller.sendToAgent) { Image(systemName: "arrow.up") }
                                .disabled(agent.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || controller.workspace?.projects.isEmpty != false)
                                .help("Enviar a Codex (⌘↩)").accessibilityLabel("Enviar a Codex")
                        }
                    }.buttonStyle(.bordered).controlSize(.small)
                }.padding(12)
            }
            if let error = agent.error {
                VStack(alignment: .leading, spacing: 6) {
                    Text(error).font(.system(size: 11)).foregroundStyle(.red.opacity(0.9)).textSelection(.enabled)
                    diagnosticsButton(agent)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
        }.background(Theme.background).task(id: controller.workspaceURL) { await agent.connect() }
        .onChange(of: agent.selectedProjectID) { _, _ in agent.clearConversation() }
        .sheet(isPresented: $showingDiagnostics) {
            VStack(spacing: 0) {
                HStack {
                    Text("Diagnóstico de Codex").font(.headline)
                    Spacer()
                    Button("Cerrar") { showingDiagnostics = false }.keyboardShortcut(.cancelAction)
                }.padding(18)
                Text("Salida de error del proceso. Está solo en memoria: no se guarda ni se envía.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18)
                Divider().padding(.top, 12)
                ScrollView([.horizontal, .vertical]) {
                    Text(controller.agent.diagnostics)
                        .font(.system(size: 11, design: .monospaced)).textSelection(.enabled).padding(18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }.frame(width: 640, height: 420).background(Theme.background)
        }
        .sheet(isPresented: $showingDiff) {
            VStack(spacing: 0) {
                HStack { Text("Cambios de Codex").font(.headline); Spacer(); Button("Cerrar") { showingDiff = false }.keyboardShortcut(.cancelAction) }.padding(18)
                Divider()
                ScrollView([.horizontal, .vertical]) {
                    Text(agent.diff.isEmpty ? agent.changes.map { $0.path + "\n" + $0.diff }.joined(separator: "\n\n") : agent.diff)
                        .font(.system(size: 12, design: .monospaced)).textSelection(.enabled).padding(18)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }.frame(width: 780, height: 520)
        }
    }

    /// Antes de lanzar nada, el usuario ve qué binario se va a ejecutar.
    @ViewBuilder private func approval(_ candidate: CodexCandidate, replaces: Bool,
                                       agent: AgentController) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(replaces ? "El ejecutable de Codex cambió" : "Confirmá el ejecutable de Codex")
                .font(.system(size: 12, weight: .semibold))
            Text(replaces
                 ? "El binario no es el que aprobaste antes. Revisá la ruta antes de continuar."
                 : "Krabzik va a ejecutar este programa con tu entorno completo.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                Text(candidate.url.path).textSelection(.enabled)
                Text(candidate.signature.label)
                Text(ByteCountFormatter.string(fromByteCount: candidate.identity.size, countStyle: .file)
                    + " · sha256 " + candidate.identity.shortDigest)
            }
            .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8).background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 5))
            HStack {
                Button("Elegir otro…", action: agent.chooseExecutable)
                Spacer()
                Button("Usar este ejecutable") { agent.approve(candidate) }
            }.controlSize(.small)
        }
        .padding(16).frame(maxWidth: 420)
    }
}

private struct AgentMessageView: View {
    let message: AgentMessage
    var body: some View {
        Text(message.text).font(.system(size: 12)).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading).padding(message.isUser ? 10 : 0)
            .background(message.isUser ? Theme.blue.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 7))
    }
}

private struct AgentRequestView: View {
    let request: AgentRequest
    let agent: AgentController
    @State private var answers: [String: String] = [:]
    @State private var acceptsSecretRisk = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if request.isQuestion { questions } else { approval }
        }.buttonStyle(.bordered).controlSize(.small)
    }

    /// Procedencia explícita: lo que sigue lo escribió el modelo, no la interfaz.
    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: request.isQuestion ? "questionmark.bubble" : "hand.raised")
                .font(.system(size: 11))
            Text(request.isQuestion ? "Codex pregunta" : "Codex pide permiso")
                .font(.system(size: 11, weight: .semibold))
            Spacer()
        }.foregroundStyle(Theme.blue)
    }

    private var questions: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(request.params["questions"].array.enumerated()), id: \.offset) { _, question in
                let id = question["id"].string ?? ""
                modelBlock(ModelText.display(question["question"].string ?? "", limit: 2_000))
                if question["isSecret"].bool {
                    secretField(id: id)
                } else {
                    TextField("Respuesta", text: binding(for: id))
                    ForEach(Array(question["options"].array.enumerated()), id: \.offset) { _, option in
                        let label = ModelText.display(option["label"].string ?? "", limit: 200)
                        Button(label) { answers[id] = label }
                            .help(ModelText.display(option["description"].string ?? "", limit: 500))
                    }
                }
            }
            HStack {
                Spacer()
                Button("Rechazar") { agent.answer(request, accept: false) }
                Button("Responder") { agent.answerQuestions(request, answers: answers) }
                    .disabled(answersIncomplete || (request.isSecret && !acceptsSecretRisk))
            }
        }
    }

    /// Un campo secreto no puede ser una interacción silenciosa y normal: el modelo
    /// pide el dato y la UI se lo presenta con el mismo aspecto que un campo propio.
    @ViewBuilder private func secretField(id: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10))
                Text("Codex pide un dato secreto. Krabzik nunca necesita tus contraseñas para "
                     + "trabajar. Si no sabés exactamente por qué lo pide, rechazá la pregunta.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 10)).foregroundStyle(.orange)
            Toggle("Entiendo el riesgo y quiero responder", isOn: $acceptsSecretRisk)
                .font(.system(size: 10)).toggleStyle(.checkbox)
            SecureField("Respuesta", text: binding(for: id)).disabled(!acceptsSecretRisk)
        }
        .padding(8)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    private var approval: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(request.method.contains("fileChange") ? "Permitir cambios" : "Permitir comando")
                .font(.system(size: 12, weight: .medium))
            if let reason = request.params["reason"].string {
                Text(ModelText.display(reason, limit: 2_000)).font(.system(size: 11)).textSelection(.enabled)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if let cwd = request.params["cwd"].string {
                        Text(ModelText.display(cwd, limit: 1_024)).foregroundStyle(.secondary)
                    }
                    if let root = request.params["grantRoot"].string {
                        Text(ModelText.display(root, limit: 1_024)).foregroundStyle(.secondary)
                    }
                    modelBlock(ModelText.display(request.params["command"].string
                                                 ?? agent.proposedDiff(for: request), limit: 100_000))
                }.font(.system(size: 10, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 130)
            HStack {
                Spacer()
                Button("Rechazar") { agent.answer(request, accept: false) }
                Button("Permitir una vez") { agent.answer(request, accept: true) }
            }
        }
    }

    /// Bloque con fondo propio: distingue el texto del modelo del de la interfaz.
    private func modelBlock(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(7)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 5))
    }

    private var answersIncomplete: Bool {
        request.params["questions"].array.contains { (answers[$0["id"].string ?? ""] ?? "").isEmpty }
    }

    private func binding(for id: String) -> Binding<String> {
        Binding(get: { answers[id] ?? "" }, set: { answers[id] = $0 })
    }
}

/// Owns ⌘Return while composing so it cannot execute the active SQL file.
private struct AgentComposer: NSViewRepresentable {
    @Binding var text: String
    let enabled: Bool
    let send: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(), view = ComposerTextView()
        view.isRichText = false; view.isAutomaticQuoteSubstitutionEnabled = false; view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false; view.font = .systemFont(ofSize: 12)
        view.textColor = EditorPalette.text; view.backgroundColor = EditorPalette.background
        view.textContainerInset = NSSize(width: 1, height: 5)
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]; view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: 300, height: CGFloat.greatestFiniteMagnitude)
        view.minSize = .zero; view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.delegate = context.coordinator; view.setAccessibilityLabel("Mensaje para Codex")
        scroll.documentView = view; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.owner = self
        guard let view = scroll.documentView as? ComposerTextView else { return }
        if view.string != text { view.string = text }
        view.isEditable = enabled; view.send = send
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var owner: AgentComposer
        init(_ owner: AgentComposer) { self.owner = owner }
        func textDidChange(_ notification: Notification) { if let view = notification.object as? NSTextView { owner.text = view.string } }
    }
    final class ComposerTextView: NSTextView {
        var send: (() -> Void)?
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if event.keyCode == 36, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
                if isEditable { send?() }; return true
            }
            return super.performKeyEquivalent(with: event)
        }
    }
}
