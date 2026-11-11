import SwiftUI

struct AutomationBottomPanel: View {
    @Bindable var controller: WorkspaceController
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Panel inferior", selection: $controller.automationPanelSelected) {
                    Text("Procesos").tag(false)
                    Text("Automatizaciones").tag(true)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 260)
                Spacer()
                Button { controller.processesVisible = false } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(.plain).help("Ocultar panel")
            }.padding(.horizontal, 12).frame(height: 34).background(Theme.bar)
            if controller.automationPanelSelected { AutomationPanel(controller: controller) }
            else { ProcessPanel(controller: controller) }
        }
        .onAppear { controller.configureAutomations() }
        .onChange(of: controller.workspaceURL) { _, _ in controller.configureAutomations() }
        .onChange(of: controller.automations.isRunning) { _, running in
            if !running { controller.configureAutomations() }
        }
    }
}

struct AutomationPanel: View {
    let controller: WorkspaceController
    @State private var reviewing = false
    @State private var resuming = false

    var body: some View {
        @Bindable var model = controller.automations
        VStack(spacing: 0) {
            HStack {
                Picker("Automatización", selection: $model.selectedID) {
                    Text("Seleccionar…").tag(Optional<UUID>.none)
                    ForEach(model.catalog.automations) { Text($0.name).tag(Optional($0.id)) }
                }.labelsHidden().frame(maxWidth: 250).disabled(model.isRunning)
                Button { model.showingConfiguration = true } label: { Image(systemName: "gearshape") }
                    .help("Configurar automatizaciones")
                Menu("Historial") {
                    ForEach(model.history) { item in
                        Button(item.automation.name + " · " + item.started.formatted(date: .abbreviated, time: .shortened)
                            + " · " + item.phase.label) {
                            model.showHistory(item)
                        }
                    }
                }.disabled(model.isRunning || model.history.isEmpty)
                Spacer()
                if model.isRunning {
                    if model.execution?.phase == .waiting {
                        Button("Confirmar paso") { model.confirmStep() }.disabled(controller.isReadOnly)
                    }
                    Button("Detener") { model.cancel() }
                } else {
                    if model.canResume {
                        Button("Reintentar paso") { resuming = true
                        reviewing = true }
                            .disabled(controller.isReadOnly || controller.isSwitchingWorkspace)
                    }
                    Button("Ejecutar…") { resuming = false
                    reviewing = true }
                        .disabled(model.selected == nil || controller.isReadOnly || controller.isSwitchingWorkspace)
                }
            }.controlSize(.small).padding(8).background(Theme.bar)
            if !model.message.isEmpty, model.execution?.phase != .failed {
                Text(model.message).font(.caption).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
            }
            HStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        if let execution = model.execution {
                            if execution.phase != .failed {
                                Text(execution.phase.label).font(.caption).foregroundStyle(.secondary)
                            }
                            ForEach(Array(execution.automation.steps.enumerated()), id: \.element.id) { index, step in
                                Button { model.selectStep(index) } label: {
                                    HStack {
                                        Image(systemName: icon(execution.states[index]))
                                        Text(step.name).lineLimit(1)
                                        Spacer(minLength: 0)
                                    }.font(.system(size: 11)).padding(6)
                                        .foregroundStyle(execution.states[index] == .failed ? Color.red : Color.primary)
                                        .background(stepBackground(execution.states[index], selected: index == model.selectedStep),
                                                    in: RoundedRectangle(cornerRadius: 5))
                                }.buttonStyle(.plain).disabled(model.isRunning)
                            }
                        } else { Text("Elegí una automatización para ejecutar.").font(.caption).foregroundStyle(.secondary) }
                    }.padding(8)
                }.frame(width: 210).background(Theme.bar)
                Rectangle().fill(Theme.border).frame(width: 1)
                if let run = model.currentRun {
                    ConsoleView(run: run, theme: AppSettings.shared.theme).id(run.id)
                } else if model.execution?.phase == .waiting, let execution = model.execution {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Revisá el paso antes de continuar").font(.headline)
                            Text(execution.automation.steps[execution.stepIndex].command)
                                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            Text("Los pasos anteriores no se volverán a ejecutar.").font(.caption).foregroundStyle(.secondary)
                        }.padding(12)
                    }.frame(maxWidth: .infinity)
                } else { Theme.background }
            }
        }
        .sheet(isPresented: $model.showingConfiguration) {
            VStack {
                HStack { Text("Automatizaciones").font(.headline)
                Spacer()
                    Button("Listo") { model.showingConfiguration = false }
                }.padding()
                AutomationSettingsView(controller: controller)
            }.frame(width: 720, height: 650).background(Theme.background).preferredColorScheme(.dark)
        }
        .sheet(isPresented: $reviewing) {
            if let automation = resuming ? model.execution?.automation : model.selected {
                AutomationReview(controller: controller, automation: automation, resuming: resuming)
            }
        }
    }

    private func stepBackground(_ phase: AutomationPhase, selected: Bool) -> Color {
        if phase == .failed { return Color.red.opacity(selected ? 0.20 : 0.10) }
        return selected ? Theme.accent.opacity(0.16) : .clear
    }

    private func icon(_ phase: AutomationPhase) -> String {
        switch phase {
        case .succeeded: return "checkmark.circle"
        case .running: return "play.circle"
        case .waiting: return "pause.circle"
        case .failed, .interrupted: return "exclamationmark.circle"
        case .cancelled: return "stop.circle"
        case .skipped: return "minus.circle"
        case .pending: return "circle"
        }
    }
}

private struct AutomationReview: View {
    let controller: WorkspaceController
    let automation: Automation
    let resuming: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var parameters: [AutomationVariable] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(resuming ? "Reintentar paso" : automation.name).font(.title2)
            Text(controller.automations.root?.path ?? "").font(.caption).textSelection(.enabled)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach($parameters) { $parameter in
                        HStack { Text(parameter.name).frame(width: 160, alignment: .leading)
                            TextField("Valor", text: $parameter.value).textFieldStyle(.roundedBorder).disabled(resuming)
                        }
                    }
                    Divider()
                    ForEach(automation.steps.filter(\.enabled)) { step in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(step.name).fontWeight(.medium)
                            Text("Carpeta: " + step.directory).font(.caption)
                            if !step.nodeVersion.isEmpty { Text("Node · nvm " + step.nodeVersion).font(.caption) }
                            Text(step.command).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        }
                    }
                    Text("Los scripts se ejecutan con tu usuario. Los parámetros y el historial se guardan localmente; "
                         + "usá el llavero para secretos.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(resuming ? "Reintentar" : "Ejecutar cadena") {
                    guard !controller.isReadOnly, !controller.isSwitchingWorkspace, let url = controller.workspaceURL else { return }
                    if resuming { controller.automations.resume(workspace: url, runner: controller.runner) }
                    else { controller.automations.start(automation, parameters: parameters, workspace: url, runner: controller.runner) }
                    dismiss()
                }.buttonStyle(.borderedProminent)
            }
        }.padding(20).frame(width: 640, height: 540).background(Theme.background).preferredColorScheme(.dark)
            .onAppear { parameters = resuming ? controller.automations.execution?.parameters ?? [] : automation.parameters }
    }
}
