import AppKit
import SwiftUI

struct ServicesConfigurationView: View {
    let controller: WorkspaceController
    let workspaceURL: URL
    @Environment(\.dismiss) private var dismiss
    @State private var original: [CodeProject] = []
    @State private var baseline: [CodeProject] = []
    @State private var draft: [CodeProject] = []
    @State private var selectedID: UUID?
    @State private var query = ""
    @State private var failure = ""
    @State private var loaded = false
    @State private var confirmsRemoval = false

    init(controller: WorkspaceController, workspaceURL: URL, selectedID: UUID? = nil) {
        self.controller = controller
        self.workspaceURL = workspaceURL.standardizedFileURL
        _selectedID = State(initialValue: selectedID)
    }
    private var changed: Bool { draft != baseline }
    private var selection: (Int, Int)? {
        for index in draft.indices {
            if let service = draft[index].services?.firstIndex(where: { $0.id == selectedID }) { return (index, service) }
        }
        return nil
    }
    private var editable: Bool { controller.trust.trust(for: workspaceURL) == .trusted }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Servicios · \(controller.projectModel(for: workspaceURL)?.name ?? workspaceURL.lastPathComponent)")
                    .font(.headline)
                Spacer()
            }.padding(16)
            Divider()
            HStack(spacing: 0) {
                navigator.frame(width: 250).background(Theme.sidebar)
                Divider()
                if let (parent, service) = selection, let definition = draft[parent].services?[service] {
                    let binding = Binding(get: { draft[parent].services?[service] ?? definition },
                                          set: { draft[parent].services?[service] = $0 })
                    ServiceConfigurationForm(service: binding, parent: draft[parent], workspaceURL: workspaceURL,
                                             sharedNames: sharedNames, controller: controller, hasChanges: changed,
                                             deleteService: { confirmsRemoval = true })
                        .id(definition.id).disabled(!editable)
                } else {
                    ContentUnavailableView("Configurá los servicios del proyecto", systemImage: "gearshape.2",
                                           description: Text("Elegí un subproyecto y agregá un servicio con el botón +."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            if !failure.isEmpty { Text(failure).foregroundStyle(.red).font(.callout).padding(10) }
            Divider()
            HStack {
                Text("Los cambios se aplican en la próxima ejecución.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Aplicar") { apply(close: false) }.disabled(!changed || !editable)
                Button("Guardar") { apply(close: true) }.disabled(!editable)
            }.padding(16).background(Theme.bar)
        }
        .frame(width: 1100, height: 830).background(Theme.background).tint(Theme.accent)
        .preferredColorScheme(Theme.colorScheme)
        .onAppear { load() }
        .sheet(isPresented: $confirmsRemoval) { removalConfirmation }

    }
    private var removalConfirmation: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("¿Eliminar «\(selectedServiceName)»?").font(.headline)
            Text(removalStopsProcess
                 ? "El servicio se eliminará y su proceso se detendrá cuando apliques o guardes los cambios."
                 : "El servicio se eliminará de este subproyecto cuando apliques o guardes los cambios.")
                .foregroundStyle(Theme.surfaceInk.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Spacer()
                Button("Cancelar") { confirmsRemoval = false }
                    .keyboardShortcut(.defaultAction)
                Button(role: .destructive) {
                    confirmsRemoval = false
                    removeSelected()
                } label: {
                    Text(removalStopsProcess ? "Detener y eliminar" : "Eliminar")
                        .foregroundStyle(.white).fontWeight(.medium)
                        .padding(.horizontal, 18).frame(height: 30)
                        .background(Color(red: 0.65, green: 0.12, blue: 0.12), in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }.buttonStyle(.fullArea)
            }
        }
        .padding(24).frame(width: 420).background(Theme.background)
        .foregroundStyle(Theme.surfaceInk).preferredColorScheme(Theme.colorScheme)
        .onExitCommand { confirmsRemoval = false }
    }
    private var sharedNames: [String] {
        (try? controller.terminals.sharedEnvironment(for: workspaceURL).keys.sorted()) ?? []
    }
    private var navigator: some View {
        VStack(spacing: 10) {
            TextField("Buscar servicio", text: $query).textFieldStyle(.roundedBorder).padding(12)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(draft.enumerated()), id: \.element.id) { parent, project in
                        if query.isEmpty || project.name.localizedStandardContains(query) ||
                            project.configuredServices.contains(where: { $0.name.localizedStandardContains(query) }) {
                            HStack {
                                Label(project.name, systemImage: "folder").font(.headline).lineLimit(1)
                                Spacer()
                                Button { add(parent: parent) } label: {
                                    Image(systemName: "plus").frame(width: 24, height: 24).contentShape(Rectangle())
                                }.buttonStyle(.fullArea).help("Agregar servicio a \(project.name)").disabled(!editable)
                            }.padding(.horizontal, 12).padding(.top, 8)
                            .contextMenu {
                                Button("Iniciar todos los servicios") { startParent(project.id) }.disabled(changed || !editable)
                                Button("Detener todos los servicios") {
                                    for run in controller.runner.runs.values where run.workspaceURL == workspaceURL &&
                                        (run.project?.serviceParentID ?? run.projectID) == project.id { controller.runner.stop(run.id) }
                                }
                                Button("Agregar servicio") { add(parent: parent) }.disabled(!editable)
                            }
                            ForEach(project.configuredServices) { service in
                                Button { selectedID = service.id } label: {
                                    Label(service.name, systemImage: "gearshape").lineLimit(1)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.leading, 28).padding(.trailing, 10).padding(.vertical, 9)
                                        .background(selectedID == service.id ? Theme.accent.opacity(0.2) : .clear,
                                                    in: RoundedRectangle(cornerRadius: 5)).contentShape(Rectangle())
                                }.buttonStyle(.fullArea).padding(.horizontal, 8)
                                    .accessibilityAddTraits(selectedID == service.id ? .isSelected : [])
                                    .contextMenu {
                                        Button("Duplicar servicio") { selectedID = service.id
                                        duplicate() }.disabled(!editable)
                                    }
                            }
                        }
                    }
                }
            }

        }
    }
    private var selectedRun: ProjectRun? {
        controller.runner.runs.values.first { $0.workspaceURL == workspaceURL && $0.projectID == selectedID }
    }
    private var selectedServiceName: String {
        guard let (parent, index) = selection else { return "Servicio" }
        return draft[parent].services?[index].name ?? "Servicio"
    }
    private var removalStopsProcess: Bool {
        guard let run = selectedRun else { return false }
        return run.status.active || run.pendingRestart
    }
    private func load() {
        guard !loaded else { return }
        loaded = true
        do {
            original = try Workspace.read(from: workspaceURL).projects
            var projects = original
            for parent in projects.indices {
                projects[parent].services = projects[parent].configuredServices
                for index in projects[parent].services?.indices ?? 0..<0 {
                    guard var service = projects[parent].services?[index] else { continue }
                    service.variables = try ServiceEnvironmentStore().hydrate(service.variables, serviceID: service.id,
                                                                              workspace: workspaceURL)
                    for key in service.configuration.environment.keys.sorted() {
                        if !service.variables.contains(where: { $0.name == key }) {
                            service.variables.append(TerminalEnvironmentVariable(name: key, secret: true,
                                                                                 value: service.configuration.environment[key] ?? ""))
                        }
                    }
                    service.configuration.environment = [:]
                    projects[parent].services?[index] = service
                }
            }
            draft = projects
            baseline = projects
            if selection == nil { selectedID = draft.flatMap(\.configuredServices).first?.id }
        } catch { failure = error.localizedDescription }
    }
    private func startParent(_ id: UUID) {
        guard !changed, editable, let model = try? Workspace.read(from: workspaceURL),
              let parent = model.projects.first(where: { $0.id == id }) else { return }
        controller.projects.startServices(parent, workspaceURL: workspaceURL)
    }
    private func add(parent: Int) {
        guard draft.indices.contains(parent) else { return }
        let service = ServiceConfiguration(name: "Servicio \((draft[parent].services?.count ?? 0) + 1)")
        draft[parent].services?.append(service)
        selectedID = service.id
    }
    private func duplicate() {
        guard let (parent, index) = selection, var service = draft[parent].services?[index] else { return }
        service.id = UUID()
        service.name += " copia"
        service.variables = service.variables.map { variable in var copy = variable
            copy.id = UUID()
            return copy }
        draft[parent].services?.append(service)
        selectedID = service.id
    }
    private func removeSelected() {
        guard let (parent, index) = selection, let id = draft[parent].services?[index].id else { return }
        draft[parent].services?.remove(at: index)
        for next in draft[parent].services?.indices ?? 0..<0 { draft[parent].services?[next].dependencies.removeAll { $0 == id } }
        selectedID = draft[parent].services?.first?.id
    }
    private func apply(close: Bool) {
        do {
            let changes = draft.filter { item in baseline.first { $0.id == item.id } != item }
            if !changes.isEmpty { try controller.saveServices(changes, expected: original, at: workspaceURL) }
            original = try Workspace.read(from: workspaceURL).projects
            baseline = draft
            failure = ""
            if close { dismiss() }
        } catch { failure = error.localizedDescription }
    }
}
