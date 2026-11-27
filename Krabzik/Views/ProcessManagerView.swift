import AppKit
import SwiftUI

struct ProcessManagerView: View {
    @Bindable var controller: WorkspaceController
    var detached = false
    var bottom = false
    @State private var editing: ProjectRun?
    @State private var configuringServices = false
    @State private var detail = "Logs"
    @State private var logQuery = ""
    @State private var follow = true
    @State private var pausedOutput: String?
    @State private var pausedRunID: UUID?
    @State private var workspaceFilter: URL?
    @State private var showsLogSearch = false
    @State private var showsProjectFilter = false

    private var manager: ProcessManagerPresentation { controller.processManager }
    private var runs: [ProjectRun] {
        controller.runner.runs.values.filter { run in
            guard run.project != nil else { return false }
            if manager.currentProjectOnly && run.workspaceURL != controller.workspaceURL { return false }
            if let workspaceFilter, run.workspaceURL != workspaceFilter { return false }
            let text = "\(run.name) \(run.workspaceName) \(run.project?.serviceParentName ?? "") " +
                run.ports.map(String.init).joined(separator: " ")
            return manager.query.isEmpty || text.localizedStandardContains(manager.query)
        }.sorted { ($0.workspaceName, $0.name, $0.id.uuidString) < ($1.workspaceName, $1.name, $1.id.uuidString) }
    }
    private var selected: ProjectRun? {
        runs.first { $0.id == manager.selectedID } ?? runs.first
    }
    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < Theme.zoom(650)
            VStack(spacing: 0) {
            header(compact: compact)
            if bottom {
                HSplitView {
                    processTable(compact: true).frame(minWidth: 250, idealWidth: 400)
                    if let run = selected { processDetail(run, compact: true).frame(minWidth: 250) }
                }.frame(maxHeight: .infinity)
            } else {
                VSplitView {
                    processTable(compact: compact)
                        .frame(minHeight: 180, idealHeight: detached ? 340 : 230)
                    if let run = selected { processDetail(run, compact: compact).frame(minHeight: 180, maxHeight: .infinity) }
                }
            }
            Divider()
            HStack {
                Text("\(controller.runner.runs.values.filter { $0.status.active }.count) servicios activos")
                Spacer()
                if detached { Text("Continúan activos al cambiar de proyecto") }
            }.font(Theme.interfaceFont(11)).foregroundStyle(.secondary).padding(10)
            }
        }
        .background(ProcessManagerAppearance.background).font(Theme.interfaceFont(12)).tint(Theme.accent)
        .preferredColorScheme(Theme.colorScheme)
        .onChange(of: controller.settings.resolvedTheme) { _, theme in manager.updateTheme(theme) }
        .sheet(item: $editing) { run in
            if let url = run.workspaceURL {
                ServicesConfigurationView(controller: controller, workspaceURL: url, selectedID: run.projectID)
            }
        }
        .sheet(isPresented: $configuringServices) {
            if let url = controller.workspaceURL { ServicesConfigurationView(controller: controller, workspaceURL: url) }
        }
        .task {
            while !Task.isCancelled {
                await controller.refreshManagedPorts()
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
    }
    private func processTable(compact: Bool) -> some View {
        ProcessManagerTable(runs: runs, selectedID: selected?.id, workspaceURL: controller.workspaceURL,
                            compact: compact, select: { manager.selectedID = $0.id },
                            showLogs: { manager.selectedID = $0.id
                        detail = "Logs"
                    },
                            restart: { controller.startManagedProcess($0, restart: true) },
                            toggle: { run in
                        if run.status.active || run.pendingRestart { controller.runner.stop(run.id) }
                        else { controller.startManagedProcess(run) }
                    }, edit: { editing = $0 }, openPort: { open("http://localhost:\($0)") },
                            startGroup: { url in
                           if let model = try? Workspace.read(from: url) {
                               for parent in model.projects { controller.projects.startServices(parent, workspaceURL: url) }
                           }
                       })

            .padding(.horizontal, detached ? 20 : 12).padding(.bottom, bottom ? 6 : 20)
    }
    private func header(compact: Bool) -> some View {
        Group {
        if compact {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) { titleText
                        summaryText }
                    Spacer(minLength: 4)
                    presentationControls(compact: true)
                }
                search
                projectFilter.frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                title
                Spacer(minLength: 20)
                search.frame(width: 300)
                projectFilter
                presentationControls(compact: false)
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack { title
                    Spacer()
                    presentationControls(compact: false) }
                HStack { search
                    projectFilter }
            }
        }
        }
        }.padding(.horizontal, detached ? 20 : 12).padding(.vertical, compact ? 12 : 18)
    }
    private var titleText: some View { Text("Procesos").font(Theme.interfaceFont(22, weight: .semibold)) }
    private var summaryText: some View {
        let active = controller.runner.runs.values.filter { $0.status.active }.count
        let projects = Set(controller.runner.runs.values.compactMap(\.workspaceURL)).count
        return Text("\(active) activos · \(projects) " + (projects == 1 ? "proyecto" : "proyectos"))
            .foregroundStyle(.secondary).font(Theme.interfaceFont(13)).lineLimit(1)
    }
    private var title: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            titleText
            summaryText
        }.fixedSize(horizontal: true, vertical: false)
    }
    private var search: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Buscar servicio, subproyecto o puerto", text: Binding(get: { manager.query }, set: { manager.query = $0 }))
                .textFieldStyle(.plain)
        }.padding(.horizontal, 10).frame(height: 32)
            .background(Theme.surfaceInk.opacity(0.025), in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.surfaceInk.opacity(0.28)))
    }
    private var projectFilter: some View {
        Button { showsProjectFilter.toggle() } label: {
            HStack(spacing: 18) {
                Text(filterTitle).lineLimit(1)
                Image(systemName: "chevron.down").font(Theme.interfaceFont(11))
            }.padding(.horizontal, 12).frame(height: 32)
                .background(Theme.surfaceInk.opacity(0.025), in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.surfaceInk.opacity(0.28)))
        }.buttonStyle(.fullArea).fixedSize().help("Filtrar por proyecto")
            .popover(isPresented: $showsProjectFilter, arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    filterOption("Todos los proyectos") { manager.currentProjectOnly = false
                        workspaceFilter = nil }
                    filterOption("Proyecto actual") { manager.currentProjectOnly = true
                        workspaceFilter = nil }
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(Array(Set(controller.runner.runs.values.compactMap(\.workspaceURL)))
                                .sorted(by: { $0.path < $1.path }), id: \.self) { url in
                                filterOption(controller.runner.runs.values.first(where: { $0.workspaceURL == url })?.workspaceName
                                    ?? url.lastPathComponent) {
                                    manager.currentProjectOnly = false
                                    workspaceFilter = url
                                }
                            }
                        }
                    }.frame(maxHeight: 200)
                }.padding(8).frame(width: 240).font(Theme.interfaceFont(13))
                    .onExitCommand { showsProjectFilter = false }
            }
    }
    private func filterOption(_ label: String, action: @escaping () -> Void) -> some View {
        Button { action()
            showsProjectFilter = false
        } label: {
            HStack { Text(label).lineLimit(1)
                Spacer()
                if filterTitle == label { Image(systemName: "checkmark") }
            }.padding(8).frame(maxWidth: .infinity).contentShape(Rectangle())
        }.buttonStyle(.fullArea).help(label)
    }
    private var filterTitle: String {
        if manager.currentProjectOnly { return "Proyecto actual" }
        if let workspaceFilter {
            return controller.runner.runs.values.first(where: { $0.workspaceURL == workspaceFilter })?.workspaceName
                ?? workspaceFilter.deletingPathExtension().lastPathComponent
        }
        return "Todos los proyectos"
    }
    private func presentationControls(compact: Bool) -> some View {
        HStack(spacing: 10) {
            Button { configuringServices = true } label: {
                Group {
                    if compact { Image(systemName: "gearshape").frame(width: 28, height: 28) }
                    else { Label("Configurar servicios…", systemImage: "gearshape").padding(.horizontal, 10).padding(.vertical, 7) }
                }.overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.border)).contentShape(Rectangle())
            }.buttonStyle(.fullArea).help("Abrir la configuración unificada de servicios")
                .disabled(controller.workspaceURL == nil)
            if detached {
                action(manager.staysOnTop ? "pin.fill" : "pin", "Mantener ventana por encima") { manager.staysOnTop.toggle() }
            }
            action(detached ? "sidebar.right" : "macwindow.on.rectangle",
                   detached ? "Acoplar al lateral del proyecto" : "Abrir en ventana independiente") {
                if detached { manager.dock(controller) } else { manager.detach(controller) }
            }
            if !detached {
                action(bottom ? "sidebar.right" : "rectangle.bottomthird.inset.filled",
                       bottom ? "Mover procesos al lateral" : "Mover procesos abajo") {
                    controller.moveProcessesPanel(to: bottom ? .right : .bottom)
                }
                action("minus", "Minimizar panel de procesos") {
                    controller.processesVisible = false
                    manager.wasVisible = false
                    controller.pixelProcessesVisible = false
                }
            }
        }
    }
    private func processDetail(_ run: ProjectRun, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(run.name).font(Theme.interfaceFont(20, weight: .semibold))
                    Text("\(run.workspaceName) › \(run.project?.serviceParentName ?? run.name)")
                        .foregroundStyle(.secondary).font(Theme.interfaceFont(13))
                }
                Spacer()
                if !compact {
                Button("Editar servicio…", systemImage: "gearshape") { editing = run }
                Button { openProject(run) } label: {
                    HStack(spacing: 8) { Text("Abrir subproyecto")
                        Image(systemName: "arrow.up.right") }
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.surfaceInk.opacity(0.3)))
                }.buttonStyle(.fullArea).help("Abrir el proyecto de este proceso")
                }
            }.padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 14)
            HStack(spacing: 0) {
                ForEach(["Logs", "Puertos", "Detalles"], id: \.self) { tab in
                    Button { detail = tab } label: {
                        Text(tab).font(Theme.interfaceFont(14, weight: detail == tab ? .semibold : .regular))
                            .padding(.horizontal, compact ? 10 : 20).frame(height: 44)
                            .overlay(alignment: .bottom) {
                                if detail == tab { ProcessManagerAppearance.link.frame(height: 3) }
                            }
                            .contentShape(Rectangle())
                    }.buttonStyle(.fullArea).help("Mostrar \(tab.lowercased()) del proceso")
                }
                Spacer(minLength: 8)
                if detail == "Logs" && !compact { logControls(run) }
            }.padding(.horizontal, 4)
            if detail == "Logs" && compact {
                HStack { Spacer()
                    logControls(run)
                }.padding(.vertical, 4)
            }
            Divider()
            if detail == "Logs" { logs(run) }
            else if detail == "Puertos" {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(manager.listeners.filter { $0.group == run.processID }) { listener in
                            Text(":\(listener.port) · \(listener.command) · PID \(listener.pid)")
                        }
                        if run.ports.isEmpty { Text("Sin puertos TCP en escucha").foregroundStyle(.secondary) }
                        if !run.portConflict.isEmpty {
                            Text(run.portConflict).foregroundStyle(.orange)
                            if let expected = run.project?.runConfiguration?.expectedPort {
                                ForEach(manager.listeners.filter { $0.port == expected && $0.group != run.processID }) { owner in
                                    Button("Localizar \(owner.command) · PID \(owner.pid)") {
                                        if let other = controller.runner.runs.values.first(where: { $0.processID == owner.group }) {
                                            manager.selectedID = other.id
                                            manager.query = ""
                                            manager.currentProjectOnly = false
                                        } else { copy("\(owner.command) · PID \(owner.pid) · puerto \(owner.port)") }
                                    }.help("Seleccionar el proceso administrado o copiar los datos del proceso externo")
                                }
                            }
                        }
                        if let expected = run.project?.runConfiguration?.expectedPort { Text("Puerto esperado: \(expected)") }
                    }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).padding(20)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Estado: \(run.status.label)")
                        Text("PID: \(run.processID > 0 ? String(run.processID) : "—")")
                        if let project = run.project, let url = run.workspaceURL {
                            Text(project.executionCommand).font(Theme.codeFont(12))
                            Text(project.executionDirectory(relativeTo: url).path)
                            Button("Copiar comando") { copy(project.executionCommand) }
                            if let address = project.runConfiguration?.launchURL, !address.isEmpty {
                                Button("Abrir URL") { open(address) }
                            }
                        }
                        if let date = run.startedAt { Text("Inicio: \(date.formatted())") }
                        if let date = run.endedAt { Text("Fin: \(date.formatted())") }
                        if case .failed(let reason) = run.status { Text(reason).foregroundStyle(.red) }
                    }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).padding(20)
                }
            }
            Spacer(minLength: 0)
        }.id(run.id)
    }
    private func logControls(_ run: ProjectRun) -> some View {
        HStack(spacing: 12) {
            action("magnifyingglass", "Buscar en logs") {
                showsLogSearch.toggle()
                if !showsLogSearch { logQuery = "" }
            }
            Button {
                follow.toggle()
                pausedOutput = follow ? nil : run.output
                pausedRunID = run.id
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: follow ? "pause" : "play")
                        .frame(width: 28, height: 24)
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.surfaceInk.opacity(0.3)))
                    if detached { Text("Autodesplazamiento").font(Theme.interfaceFont(12)) }
                }
            }.buttonStyle(.fullArea).help(follow ? "Pausar seguimiento de logs" : "Seguir los logs")
            Divider().frame(height: 18)
            Button {
                run.output = ""
                run.revision += 1
                pausedOutput = nil
            } label: { Label("Limpiar", systemImage: "trash").font(Theme.interfaceFont(12)) }
                .buttonStyle(.fullArea).help("Limpiar los logs de este proceso")
        }.foregroundStyle(.secondary).padding(.trailing, 16)
    }
    private func logs(_ run: ProjectRun) -> some View {
        VStack(spacing: 0) {
            if showsLogSearch {
                TextField("Buscar en logs", text: $logQuery).textFieldStyle(.roundedBorder).padding(12)
            }
            ScrollViewReader { scroll in
                ScrollView([.vertical, .horizontal]) {
                    Text(filteredLog(run)).font(Theme.codeFont(14)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(20)
                    Color.clear.frame(height: 1).id("log-end")
                }
                .onChange(of: run.revision) { _, _ in if follow { scroll.scrollTo("log-end", anchor: .bottom) } }
            }
        }.onChange(of: run.id) { _, _ in pausedOutput = nil }
    }
    private func filteredLog(_ run: ProjectRun) -> String {
        let output = pausedRunID == run.id ? (pausedOutput ?? run.output) : run.output
        if logQuery.isEmpty { return output.isEmpty ? "Todavía no hay salida." : output }
        return output.components(separatedBy: .newlines).filter { $0.localizedStandardContains(logQuery) }.joined(separator: "\n")
    }
    private func action(_ icon: String, _ help: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) { Image(systemName: icon).frame(width: 26, height: 24).contentShape(Rectangle()) }
            .buttonStyle(.borderless).help(help).accessibilityLabel(help)
    }
    private func openProject(_ run: ProjectRun) {
        guard let url = run.workspaceURL else { return }
        Task {
            await controller.openWorkspace(url)
            manager.reopenWorkspace?()
        }
    }
    private func open(_ address: String) {
        if let url = RunConfigurationEditor.browserURL(address) { NSWorkspace.shared.open(url) }
    }
    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
