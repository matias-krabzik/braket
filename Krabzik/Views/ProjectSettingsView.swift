import AppKit
import SwiftUI

struct ProjectSettingsModal: View {
    let controller: WorkspaceController
    let workspace: Workspace
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Configuración del proyecto").font(.headline)
                Spacer()
                Text(workspace.name).foregroundStyle(.secondary).lineLimit(1)
            }.padding(20)
            Divider()
            ProjectSettingsView(controller: controller, workspace: workspace, url: url)
            Divider()
            HStack {
                Spacer()
                Button("Cerrar") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(16).background(Theme.bar)
        }
        .frame(width: 700, height: 700)
        .background(Theme.background)
        .tint(Theme.accent)
        .preferredColorScheme(Theme.colorScheme)
    }
}

struct ProjectSettingsView: View {
    let controller: WorkspaceController
    let url: URL
    @State private var terminalEnvironment = false
    @State private var timeoutOverride: Bool
    @State private var timeoutSeconds: Int
    @State private var name: String
    @State private var icon: ProjectIconStyle
    @State private var editing: CodeProject?
    @State private var codeIconMonochrome: Bool
    private let presets = ["687080", "4589E8", "8863D7", "D662AD", "DB8746", "4B9F83"]

    init(controller: WorkspaceController, workspace: Workspace, url: URL) {
        self.controller = controller
        self.url = url
        _timeoutOverride = State(initialValue: workspace.sqlTimeoutSeconds != nil)
        _timeoutSeconds = State(initialValue: workspace.sqlTimeoutSeconds ?? controller.settings.defaultSQLTimeoutSeconds)
        _name = State(initialValue: workspace.name)
        _icon = State(initialValue: workspace.iconStyle)
        _codeIconMonochrome = State(initialValue: workspace.codeIconMonochrome)
    }

    private var hasChanges: Bool {
        name != controller.workspace?.name || icon != controller.workspace?.iconStyle
            || codeIconMonochrome != controller.workspace?.codeIconMonochrome
    }

    var body: some View {
        VStack(spacing: 0) {
            if controller.isReadOnly {
                Text("Proyecto en solo lectura. Confiá en él desde el editor para modificarlo.")
                    .font(.callout).foregroundStyle(.secondary).padding()
            }
            Form {
                Section("Terminales") {
                    Button("Variables de entorno compartidas…") { terminalEnvironment = true }
                    Text("Se heredan en todas las terminales de este proyecto; cada terminal puede sobrescribirlas.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Section("Identidad") {
                    HStack(spacing: 20) {
                        ProjectIcon(name: name, style: icon, size: 64)
                        TextField("Nombre", text: $name)
                    }
                    .padding(.vertical, 8)
                    ProjectIconLettersField(letters: $icon.letters)
                    Toggle("Efecto glass", isOn: $icon.glass)
                    HStack(spacing: 12) {
                        Text("Tonos")
                        Spacer()
                        ForEach(presets, id: \.self) { hex in
                            Button { icon.hex = hex } label: {
                                Circle().fill(ProjectIconStyle(hex: hex).color).frame(width: 24, height: 24)
                                    .overlay { Circle().strokeBorder(.white.opacity(icon.hex == hex ? 0.9 : 0), lineWidth: 2) }
                            }
                            .buttonStyle(.fullArea)
                            .accessibilityLabel("Color " + hex)
                        }
                    }
                    ColorPicker("Color personalizado", selection: Binding(get: { icon.color }, set: { icon.setColor($0) }),
                                supportsOpacity: false)
                    HStack {
                        Spacer()
                        Button("Guardar cambios") {
                            controller.saveProjectIdentity(name: name, icon: icon, codeIconMonochrome: codeIconMonochrome)
                        }
                            .disabled(!hasChanges || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                Section("SQL") {
                    Toggle("Usar un timeout propio del proyecto", isOn: $timeoutOverride)
                    HStack {
                        Text("Límite por sentencia")
                        Spacer()
                        TextField("Segundos", value: $timeoutSeconds, format: .number.grouping(.never))
                            .frame(width: 80).disabled(!timeoutOverride)
                            .accessibilityLabel("Timeout SQL del proyecto en segundos")
                        Text("segundos")
                    }
                    Text("Sin un valor propio se hereda el de la aplicación: \(controller.settings.defaultSQLTimeoutSeconds) s. "
                         + "Cada sentencia del archivo tiene este límite, salvo que el archivo tenga un ajuste propio.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Guardar timeout") {
                        controller.saveProjectSQLTimeout(timeoutOverride ? timeoutSeconds : nil)
                    }.disabled((timeoutOverride && !(1...3600).contains(timeoutSeconds))
                               || (timeoutOverride ? timeoutSeconds : nil) == controller.workspace?.sqlTimeoutSeconds)
                }
                Section("Ubicación del proyecto") {
                    Text(url.path).font(.callout).textSelection(.enabled)
                    HStack {
                        Button("Mostrar en Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        Spacer()
                        Button("Cambiar ubicación…", action: relocate).disabled(hasChanges)
                    }
                    if !ProjectStorage.contains(url) {
                        Button("Migrar a BraketProjects") {
                            let folder = ProjectStorage.folder(name: name, year: Calendar.current.component(.year, from: Date()))
                            Task { await controller.relocateWorkspace(to: folder.appendingPathComponent(url.lastPathComponent),
                                                                      createDirectory: true) }
                        }.disabled(hasChanges || controller.isReadOnly || controller.isSwitchingWorkspace)
                        Text("Destino: ~/BraketProjects/<año actual>/<NombreDelProyecto>/")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Se mueve solo el archivo del proyecto. Las carpetas de código permanecen donde están.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Iconos del explorador") {
                    Picker("Apariencia", selection: $codeIconMonochrome) {
                        Text("Color").tag(false)
                        Text("Monocromático").tag(true)
                    }.pickerStyle(.segmented)
                    Text("Se aplica a archivos y subproyectos. Podés elegir otro estilo al editar cada subproyecto.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Aplicar apariencia") {
                        controller.saveProjectIdentity(name: name, icon: icon, codeIconMonochrome: codeIconMonochrome)
                    }.disabled(!hasChanges)
                }
                Section("Subproyectos") {
                    ForEach(controller.workspace?.projects ?? []) { project in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(project.name)
                                Text(project.path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Button("Editar") { editing = project }
                            Button { controller.projects.remove(project.id) } label: { Image(systemName: "minus.circle") }
                                .help("Quitar del proyecto; los archivos se conservan")
                                .accessibilityLabel("Quitar " + project.name)
                        }
                    }
                    Button("Agregar carpeta…", action: controller.projects.addFolders)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .disabled(controller.isReadOnly || controller.isSwitchingWorkspace)
        }
        .sheet(isPresented: $terminalEnvironment) {
            TerminalEnvironmentEditor(manager: controller.terminals, projectURL: url)
        }
        .sheet(item: $editing) { project in
            SubprojectSettingsSheet(controller: controller, project: project, workspaceURL: url)
        }
    }

    private func relocate() {
        let panel = NSOpenPanel()
        panel.title = "Elegí la nueva ubicación del proyecto"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = url.deletingLastPathComponent()
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        Task { await controller.relocateWorkspace(to: folder.appendingPathComponent(url.lastPathComponent)) }
    }
}

private struct SubprojectSettingsSheet: View {
    let controller: WorkspaceController
    @State var project: CodeProject
    let workspaceURL: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Editar subproyecto").font(.title2.weight(.semibold))
            Form {
                TextField("Nombre", text: $project.name)
                TextField("Carpeta", text: $project.path)
                Button("Elegir carpeta…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.directoryURL = project.directory(relativeTo: workspaceURL)
                    if panel.runModal() == .OK, let url = panel.url { project.path = url.path }
                }
                Picker("Tipo", selection: $project.kind) {
                    ForEach(ProjectKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                TextField("Comando", text: $project.command)
            }
            Divider()
            SubprojectIconEditor(project: $project, workspaceURL: workspaceURL,
                                 monochrome: controller.workspace?.codeIconMonochrome == true)
            HStack {
                Spacer()
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Guardar") {
                    Task { if await controller.saveSubproject(project) { dismiss() } }
                }.keyboardShortcut(.defaultAction).disabled(project.icon?.isValid == false)
            }
        }
        .padding(24).frame(width: 500)
        .disabled(controller.isSwitchingWorkspace)
    }
}
