import AppKit
import SwiftUI

struct ServiceConfigurationForm: View {
    @Binding var service: ServiceConfiguration
    let parent: CodeProject
    let workspaceURL: URL
    let sharedNames: [String]
    let controller: WorkspaceController
    let hasChanges: Bool
    let deleteService: () -> Void
    private var run: ProjectRun? {
        controller.runner.runs.values.first { $0.projectID == service.id && $0.workspaceURL == workspaceURL }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(service.name).font(.title2.weight(.semibold))
                    Text("\(controller.projectModel(for: workspaceURL)?.name ?? "Proyecto") › \(parent.name)")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack(spacing: 5) {
                        Circle().fill(run.map(ProcessManagerAppearance.statusColor) ?? .secondary).frame(width: 8, height: 8)
                        Text(run?.pendingRestart == true ? "Iniciando…" : run?.status.label ?? "Detenido").font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                action(run?.status.active == true || run?.pendingRestart == true ? "stop.fill" : "play.fill",
                       "Iniciar o detener servicio", tint: run?.status.active == true ? .red : .green) {
                    if let run, run.status.active || run.pendingRestart { controller.runner.stop(run.id) }
                    else { start(restart: false) }
                }.disabled(hasChanges || (service.php == nil && service.node == nil && service.command.isEmpty))
                action("arrow.counterclockwise", "Reiniciar con la configuración guardada") { start(restart: true) }
                    .disabled(hasChanges || (service.php == nil && service.node == nil && service.command.isEmpty))
            }.padding(20)
            Divider()
            Form {
                Section("Ejecución") {
                    TextField("Nombre", text: $service.name)
                    HStack {
                        TextField("Carpeta", text: $service.configuration.workingDirectory, prompt: Text("Carpeta del subproyecto"))
                        action("folder", "Elegir carpeta", perform: chooseFolder)
                    }
                    if service.php == nil && service.node == nil { TextField("Comando", text: $service.command).font(Theme.codeFont(12))
                    TextField("Argumentos · uno por línea", text: arguments, axis: .vertical).lineLimit(1...4)
                    Text("Carpeta relativa al subproyecto \(parent.name). Los argumentos se pasan como valores literales.")
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    TextField("Shell", text: shell).font(Theme.codeFont(12))
                    Toggle("Cargar perfil del shell", isOn: option(\.loadShellProfile, default: true))
                }
                PHPServiceForm(service: $service, parent: parent, workspaceURL: workspaceURL)
                NodeServiceForm(service: $service, parent: parent, workspaceURL: workspaceURL)
                Section(service.php?.environment != .local && service.php != nil ? "Pasos previos en esta Mac" : "Pasos previos") {
                    Toggle("Inicializar nvm antes de los pasos previos", isOn: option(\.initializeNVM, default: false))
                    ForEach(Array((service.configuration.preScripts ?? []).indices), id: \.self) { index in
                        HStack(spacing: 8) {
                            Text("\(index + 1)").foregroundStyle(.secondary).frame(width: 20)
                            TextField("Ej.: nvm use v24", text: script(index), axis: .vertical)
                                .font(Theme.codeFont(12)).lineLimit(1...3)
                            action("chevron.up", "Mover paso arriba") { moveStep(index, by: -1) }.disabled(index == 0)
                            action("chevron.down", "Mover paso abajo") { moveStep(index, by: 1) }
                                .disabled(index + 1 == service.configuration.preScripts?.count)
                            action("minus.circle", "Quitar paso") { service.configuration.preScripts?.remove(at: index) }
                        }
                    }
                    HStack {
                        Button("Agregar paso", systemImage: "plus") {
                            service.configuration.preScripts = (service.configuration.preScripts ?? []) + [""]
                        }
                        Button("nvm use v24") {
                            service.configuration.initializeNVM = true
                            service.configuration.preScripts = (service.configuration.preScripts ?? []) + ["nvm use v24"]
                        }
                    }
                    Toggle("Detener el arranque si falla un paso", isOn: option(\.stopOnPreScriptFailure, default: true))
                    Text("Se ejecutan en orden y en el mismo shell del servicio: conservan exports, nvm y cambios de carpeta.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Variables de entorno") {
                    Text("Heredadas del proyecto: \(sharedNames.count)")
                        .font(.caption).foregroundStyle(.secondary).help(sharedNames.joined(separator: ", "))
                    ForEach($service.variables) { $variable in
                        HStack {
                            TextField("NOMBRE", text: $variable.name).frame(width: 160)
                            if variable.secret { SecureField("Valor", text: $variable.value) }
                            else { TextField("Valor", text: $variable.value) }
                            Toggle("Secreta", isOn: $variable.secret).toggleStyle(.checkbox)
                            action("minus.circle", "Quitar variable") { service.variables.removeAll { $0.id == variable.id } }
                        }
                    }
                    Button("Agregar variable", systemImage: "plus") { service.variables.append(TerminalEnvironmentVariable()) }
                    Text("Las variables del servicio sobrescriben las del proyecto. Los valores se guardan en el Llavero de esta Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if service.php == nil { Section("Red") {
                    HStack {
                        TextField("Puerto", text: port).frame(width: 170)
                        TextField("URL", text: $service.configuration.launchURL, prompt: Text("http://localhost:3000"))
                    }
                }
                }
                Section("Comportamiento") {
                    Toggle("Iniciar al abrir el proyecto", isOn: $service.configuration.startsAutomatically)
                    Picker("Reinicio", selection: $service.configuration.restartPolicy) {
                        ForEach(RunConfiguration.RestartPolicy.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    LabeledContent("Depende de") {
                        Menu {
                            ForEach(parent.configuredServices.filter { $0.id != service.id }) { other in
                                Toggle(other.name, isOn: dependency(other.id))
                            }
                        } label: {
                            Text(service.dependencies.isEmpty ? "Ningún servicio" : service.dependencies
                                .count == 1 ? "1 servicio" : "\(service.dependencies.count) servicios")
                        }
                    }
                    Toggle("Esperar el puerto de este servicio antes de iniciar sus dependientes", isOn: $service.waitForPort)
                    Stepper("Tiempo de espera: \(service.dependencyTimeout) s", value: $service.dependencyTimeout, in: 1...300)
                }
                if hasChanges {
                    Text("Aplicá o guardá los cambios antes de iniciar o reiniciar servicios.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Button(role: .destructive, action: deleteService) {
                        Label("Eliminar servicio", systemImage: "trash")
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8).contentShape(Rectangle())
                    }.buttonStyle(.fullArea).help("Eliminar este servicio del subproyecto")
                } header: {
                    Text("Zona de peligro").foregroundStyle(.red)
                }
            }.formStyle(.grouped).scrollContentBackground(.hidden).padding(8)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var arguments: Binding<String> {
        Binding(get: { service.configuration.arguments.joined(separator: "\n") },
                set: { service.configuration.arguments = $0.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) })
    }
    private var shell: Binding<String> {
        Binding(get: { service.configuration.shellPath ?? "/bin/zsh" }, set: { service.configuration.shellPath = $0 })
    }
    private var port: Binding<String> {
        Binding(get: { service.configuration.expectedPort.map(String.init) ?? "" }, set: {
            service.configuration.expectedPort = $0.isEmpty ? nil : Int($0) ?? 0
        })
    }
    private func option(_ key: WritableKeyPath<RunConfiguration, Bool?>, default fallback: Bool) -> Binding<Bool> {
        Binding(get: { service.configuration[keyPath: key] ?? fallback }, set: { service.configuration[keyPath: key] = $0 })
    }
    private func script(_ index: Int) -> Binding<String> {
        Binding(get: {
            service.configuration.preScripts?.indices.contains(index) == true ? service.configuration.preScripts?[index] ?? "" : "" },
                set: {
            guard service.configuration.preScripts?.indices.contains(index) == true else { return }
            service.configuration.preScripts?[index] = $0
        })
    }
    private func dependency(_ id: UUID) -> Binding<Bool> {
        Binding(get: { service.dependencies.contains(id) }, set: { enabled in
            service.dependencies.removeAll { $0 == id }
            if enabled { service.dependencies.append(id) }
        })
    }
    private func moveStep(_ index: Int, by distance: Int) {
        guard service.configuration.preScripts?.indices.contains(index + distance) == true else { return }
        service.configuration.preScripts?.swapAt(index, index + distance)
    }
    private func action(_ icon: String, _ help: String, tint: Color = .secondary, perform: @escaping () -> Void) -> some View {
        Button(action: perform) { Image(systemName: icon).foregroundStyle(tint).frame(width: 28, height: 28).contentShape(Rectangle()) }
            .buttonStyle(.fullArea).help(help).accessibilityLabel(help)
    }
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        let base = parent.directory(relativeTo: workspaceURL)
        panel.directoryURL = base
        if panel.runModal() == .OK, let url = panel.url {
            service.configuration.workingDirectory = url.path.hasPrefix(base.path + "/")
                ? String(url.path.dropFirst(base.path.count + 1)) : url.path
        }
    }
    private func start(restart: Bool) {
        guard !hasChanges else { return }
        if let run { controller.startManagedProcess(run, restart: restart) }
        else {
            guard let model = try? Workspace.read(from: workspaceURL),
                  let parent = model.projects.first(where: { $0.id == self.parent.id }) else { return }
            controller.projects.startServices(parent, workspaceURL: workspaceURL, serviceID: service.id)
        }
    }
}
