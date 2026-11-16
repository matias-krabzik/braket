import SwiftUI

/// La conexión que usan las automatizaciones; no abre una conversación de Codex.
struct CodexConnectionSheet: View {
    @Bindable var controller: WorkspaceController
    let onClose: () -> Void

    var body: some View {
        let agent = controller.agent
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Conexión de Codex").font(.headline)
                Spacer()
                Button("Cerrar", action: onClose).keyboardShortcut(.cancelAction)
            }
            Divider()
            if agent.isConnecting {
                ProgressView("Conectando…")
            } else if let candidate = agent.pendingCandidate {
                Text(agent.replacesApprovedBinary ? "El ejecutable de Codex cambió" : "Confirmá el ejecutable de Codex")
                    .font(.subheadline.weight(.semibold))
                Text(candidate.url.path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Text(candidate.signature.label).font(.caption).foregroundStyle(.secondary)
                Text(ByteCountFormatter.string(fromByteCount: candidate.identity.size, countStyle: .file)
                     + " · sha256 " + candidate.identity.shortDigest)
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                HStack {
                    Button("Elegir otro…", action: agent.chooseExecutable)
                    Spacer()
                    Button("Usar este ejecutable") { agent.approve(candidate) }
                }
            } else if agent.missingExecutable {
                Text(agent.error ?? "No se encontró Codex en esta Mac.")
                Button("Seleccionar Codex…", action: agent.chooseExecutable)
            } else if !agent.connected {
                Button("Conectar Codex") { Task { await agent.connect() } }
            } else if agent.account.isEmpty {
                if agent.loginPending {
                    Text("Continuá en el navegador.")
                    Button("Cancelar", action: agent.cancelLogin)
                } else {
                    Button("Iniciar sesión con ChatGPT", action: agent.login)
                }
            } else {
                Label("Codex conectado para las automatizaciones", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(agent.account).foregroundStyle(.secondary)
            }
            if let error = agent.error, !agent.missingExecutable {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: 430, height: 250)
        .background(Theme.background)
        .task(id: controller.workspaceURL) {
            if !controller.isReadOnly { await agent.connect() }
        }
    }
}
