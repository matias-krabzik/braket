import SwiftUI
import UniformTypeIdentifiers

struct AutomationSettingsView: View {
    let controller: WorkspaceController
    @State private var choosingRoot = false

    var body: some View {
        @Bindable var model = controller.automations
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Carpeta de código").font(.headline)
                HStack {
                    Text(model.root?.path ?? "").font(.caption).textSelection(.enabled)
                    Spacer()
                    Button("Elegir…") { choosingRoot = true }
                }
                Text("Configuración compartida: .braket/automations.json. El historial permanece en esta Mac.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Menu("Agregar") {
                        Button("Cadena de scripts") { add(AutomationTemplates.script) }
                        Button("Publicar Braket · macOS") { add(AutomationTemplates.braket) }
                    }
                    Button("Recargar") { model.reload() }
                    Spacer()
                    Button("Guardar") { model.save() }.buttonStyle(.borderedProminent)
                }
                if !model.message.isEmpty { Text(model.message).font(.caption).foregroundStyle(.secondary) }
                ForEach($model.catalog.automations) { $automation in
                    DisclosureGroup {
                        AutomationEditor(automation: $automation)
                        Button("Eliminar automatización", role: .destructive) {
                            model.catalog.automations.removeAll { $0.id == automation.id }
                        }
                    } label: { Text(automation.name).fontWeight(.medium) }
                    Divider()
                }
                if model.catalog.automations.isEmpty {
                    Text("Agregá una automatización o elegí una carpeta con configuración existente.")
                }
            }.padding(16)
        }
        .disabled(controller.isReadOnly || model.isRunning)
        .onAppear { controller.configureAutomations() }
        .fileImporter(isPresented: $choosingRoot, allowedContentTypes: [.folder]) { result in
            if case .success(let root) = result { controller.configureAutomations(root: root) }
        }
    }

    private func add(_ automation: Automation) {
        controller.automations.catalog.automations.append(automation)
        controller.automations.selectedID = automation.id
    }
}

private struct AutomationEditor: View {
    @Binding var automation: Automation

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Nombre", text: $automation.name).textFieldStyle(.roundedBorder)
            Text("Parámetros al iniciar").font(.headline)
            AutomationVariablesEditor(variables: $automation.parameters)
            Text("Accedé desde los scripts con $BRAKET_INPUT_NOMBRE. No guardes contraseñas en estos campos.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach($automation.steps) { $step in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Toggle("Habilitado", isOn: $step.enabled).labelsHidden()
                        TextField("Nombre del paso", text: $step.name)
                        Button { move(step.id, offset: -1) } label: { Image(systemName: "arrow.up") }
                            .disabled(automation.steps.first?.id == step.id)
                        Button { move(step.id, offset: 1) } label: { Image(systemName: "arrow.down") }
                            .disabled(automation.steps.last?.id == step.id)
                        Button { automation.steps.removeAll { $0.id == step.id } } label: { Image(systemName: "minus.circle") }
                    }
                    TextField("Directorio relativo o absoluto", text: $step.directory).textFieldStyle(.roundedBorder)
                    Text("Script · zsh").font(.caption)
                    TextEditor(text: $step.command).font(.system(.caption, design: .monospaced)).frame(height: 90)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.border))
                    DisclosureGroup("Entorno y ejecución") {
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("Node con nvm (opcional, ej. 22)", text: $step.nodeVersion)
                            AutomationVariablesEditor(variables: $step.environment)
                            HStack {
                                Text("Tiempo máximo (segundos)")
                                TextField("1800", value: $step.timeoutSeconds, format: .number).frame(width: 90)
                            }
                            Toggle("Pausar para confirmar antes de ejecutar", isOn: $step.requiresConfirmation)
                            Toggle("Permitir reintentar este paso", isOn: $step.retryable)
                            Text("Activá reintentos solo si el script puede repetirse sin duplicar cambios o publicaciones.")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(.top, 6)
                    }
                }.padding(10).background(Theme.sidebar, in: RoundedRectangle(cornerRadius: 6))
            }
            Button("Agregar paso") { automation.steps.append(AutomationStep()) }
        }.padding(.vertical, 8)
    }

    private func move(_ id: UUID, offset: Int) {
        guard let index = automation.steps.firstIndex(where: { $0.id == id }),
              automation.steps.indices.contains(index + offset) else { return }
        automation.steps.swapAt(index, index + offset)
    }
}

struct AutomationVariablesEditor: View {
    @Binding var variables: [AutomationVariable]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach($variables) { $variable in
                HStack {
                    TextField("NOMBRE", text: $variable.name).frame(width: 150)
                    TextField("Valor", text: $variable.value)
                    Button { variables.removeAll { $0.id == variable.id } } label: { Image(systemName: "minus.circle") }
                }.textFieldStyle(.roundedBorder)
            }
            Button("Agregar variable") { variables.append(AutomationVariable()) }
        }
    }
}
