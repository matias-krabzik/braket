import SwiftUI

enum Theme {
    static let background = Color(nsColor: EditorPalette.background)
    static let sidebar = Color(red: 0.135, green: 0.147, blue: 0.169)
    static let bar = Color(red: 0.123, green: 0.135, blue: 0.157)
    static let border = Color.white.opacity(0.07)
    static let blue = Color(red: 0.47, green: 0.67, blue: 0.91)
}

struct WorkspaceView: View {
    @Bindable var controller: WorkspaceController

    var body: some View {
        VStack(spacing: 0) {
            if let workspace = controller.workspace, let url = controller.workspaceURL {
                if controller.isReadOnly { readOnlyBanner }
                HSplitView {
                    if controller.sidebarVisible {
                        sidebar(workspace, url: url)
                            .frame(minWidth: 210, idealWidth: 260, maxWidth: 310)
                    }
                    VSplitView {
                        editor.frame(minWidth: 520, maxWidth: .infinity, minHeight: 240, maxHeight: .infinity)
                        if let document = controller.selectedDocument, document.language == "SQL", controller.database.resultsVisible,
                           document.sqlExecution.isRunning || document.sqlExecution.error != nil || !document.sqlExecution.results.isEmpty {
                            SQLResultsPanel(execution: document.sqlExecution) { controller.database.resultsVisible = false }
                                .frame(minHeight: 140, idealHeight: 220, maxHeight: 350)
                        } else if controller.processesVisible && !controller.runnableProjects.isEmpty {
                            ProcessPanel(controller: controller)
                                .frame(minHeight: 110, idealHeight: 190, maxHeight: 240)
                        }
                    }
                    if controller.agent.visible {
                        AgentPanel(controller: controller).frame(minWidth: 300, idealWidth: 350, maxWidth: 460)
                    }
                }
                EditorStatusBar(document: controller.selectedDocument)
            } else {
                WelcomeView(controller: controller)
            }
        }
        .background(Theme.background)
        .preferredColorScheme(.dark)
        .frame(minWidth: 900, minHeight: 580)
        .toolbar {
            if controller.workspace != nil {
                ToolbarItem(placement: .navigation) {
                    Button { Task { await controller.closeWorkspace() } } label: { Image(systemName: "house") }
                        .help("Cerrar proyecto y volver al inicio")
                        .accessibilityLabel("Volver al inicio")
                        .disabled(controller.isSwitchingWorkspace)
                }
                ToolbarItem(placement: .navigation) {
                    Button { controller.sidebarVisible.toggle() } label: { Image(systemName: "sidebar.left") }
                        .help("Mostrar explorador")
                        .disabled(controller.workspace == nil)
                }
                ToolbarItem(placement: .navigation) {
                    Menu {
                        Button("Crear proyecto…", action: controller.createWorkspace)
                        Button("Abrir proyecto…", action: controller.chooseWorkspace)
                        if !controller.recentProjects.isEmpty {
                            Divider()
                            ForEach(controller.recentProjects, id: \.self) { url in
                                Button(url.deletingPathExtension().lastPathComponent) { Task { await controller.openWorkspace(url) } }
                            }
                        }
                    } label: {
                        Text(controller.workspace?.name ?? "Proyectos").font(.system(size: 13, weight: .medium))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(controller.isSwitchingWorkspace)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { controller.agent.visible.toggle() } label: { Image(systemName: "sparkles") }
                        .help("Mostrar Codex").accessibilityLabel("Mostrar Codex")
                        .disabled(controller.isReadOnly)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(action: controller.startAll) { Image(systemName: "play.fill") }
                        .help("Iniciar proyecto")
                        .disabled(controller.runnableProjects.isEmpty || controller.runnableProjects
                            .allSatisfy { controller.runner.runs[$0.id]?.status.active == true })
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        if controller.selectedDocument?.language == "SQL" { controller.database.resultsVisible.toggle() }
                        else { controller.processesVisible.toggle() }
                    } label: { Image(systemName: "rectangle.bottomthird.inset.filled") }
                        .help("Mostrar procesos")
                        .disabled(controller.runnableProjects.isEmpty && controller.selectedDocument?.language != "SQL")
                }
            }
        }
        .sheet(item: $controller.commandProject) { project in
            CommandSheet(project: project) { controller.updateProject($0) }
        }
        .sheet(item: Binding(get: { controller.database.editingConnection },
                             set: { controller.database.editingConnection = $0 })) { connection in
            ConnectionSheet(connection: connection, controller: controller)
        }
        .alert("No se pudo completar",
               isPresented: Binding(get: { controller.errorMessage != nil }, set: { if !$0 { controller.errorMessage = nil } })) {
            Button("Aceptar") { controller.errorMessage = nil }
        } message: { Text(controller.errorMessage ?? "") }
        .task { await controller.start() }
    }

    /// Barra persistente: en solo lectura el usuario tiene que saber por qué no puede
    /// ejecutar nada, y poder confiar en el proyecto desde ahí.
    private var readOnlyBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock").font(.system(size: 11))
            Text("Proyecto no confiable · solo lectura")
                .font(.system(size: 11, weight: .medium))
            Text("No se ejecutan procesos ni se habilita Codex.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Button("Confiar") { controller.trustCurrentWorkspace() }
                .controlSize(.small)
        }
        .padding(.horizontal, 16).frame(height: 32)
        .background(Color.orange.opacity(0.12))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private func sidebar(_ workspace: Workspace, url: URL) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("Código").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Button(action: controller.addFolders) { Image(systemName: "plus").font(.system(size: 11)) }
                    .buttonStyle(.plain).help("Agregar subproyecto")
                    .accessibilityLabel("Agregar subproyecto")
            }
            .padding(.horizontal, 15).padding(.top, 15).padding(.bottom, 9)
            if workspace.projects.isEmpty {
                Button("Agregar carpeta…", action: controller.addFolders)
                    .buttonStyle(.plain).foregroundStyle(Theme.blue)
                    .padding(.top, 16)
                Spacer()
            } else {
                FileTree(workspace: workspace, workspaceURL: url, revision: controller.treeRevision, controller: controller)
            }
            Rectangle().fill(Theme.border).frame(height: 1)
            DatabaseSidebar(controller: controller)
        }
        .background(Theme.sidebar)
    }

    private var editor: some View {
        VStack(spacing: 0) {
            if !controller.documents.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(controller.documents) { document in
                            DocumentTab(document: document, selected: controller.selectedDocumentID == document.id,
                                        select: { controller.selectedDocumentID = document.id },
                                        close: { controller.closeDocument(document) })
                        }
                    }
                }
                .background(Theme.bar)
                Rectangle().fill(Theme.border).frame(height: 1)
            }
            if let document = controller.selectedDocument {
                HStack(spacing: 7) {
                    Text(breadcrumb(document.url)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .padding(.horizontal, 20).frame(height: 31)
                .background(Theme.background)
                if document.hasExternalChange {
                    HStack {
                        Text("El archivo cambió en disco.").foregroundStyle(.orange)
                        Spacer()
                        Button("Recargar") { controller.reloadDocument(document) }
                    }.font(.system(size: 11)).padding(.horizontal, 18).padding(.vertical, 6)
                }
                if document.language == "SQL" { SQLToolbar(document: document, controller: controller) }
                CodeEditor(document: document).id(document.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "curlybraces").font(.system(size: 43, weight: .ultraLight)).foregroundStyle(.quaternary)
                    Text(controller.workspace?.name ?? "").font(.system(size: 13)).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func breadcrumb(_ url: URL) -> String {
        guard let workspaceURL = controller.workspaceURL else { return url.lastPathComponent }
        for project in controller.workspace?.projects ?? [] {
            let path = project.directory(relativeTo: workspaceURL).path + "/"
            if url.path.hasPrefix(path) {
                return project.name + "  /  " + String(url.path.dropFirst(path.count)).replacingOccurrences(of: "/", with: "  /  ")
            }
        }
        return url.lastPathComponent
    }

}

private struct EditorStatusBar: View {
    let document: EditorDocument?

    var body: some View {
        HStack(spacing: 18) {
            if let document {
                if document.isSaving { Text("Guardando…") }
                Spacer()
                Text("\(document.line):\(document.column)").monospacedDigit()
                Text(document.language)
                Text("UTF-8")
            } else { Spacer() }
        }
        .font(.system(size: 10)).foregroundStyle(.secondary)
        .padding(.horizontal, 16).frame(height: 25)
        .background(Theme.bar)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }
}

private struct DocumentTab: View {
    let document: EditorDocument
    let selected: Bool
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: select) {
                Text(document.url.lastPathComponent).font(.system(size: 12))
                    .lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(selected ? .primary : .secondary)
                    .frame(maxWidth: 210)
            }
            .buttonStyle(.plain)
            Button(action: close) {
                Image(systemName: document.isDirty ? "circle.fill" : "xmark")
                    .font(.system(size: document.isDirty ? 6 : 9))
                    .frame(width: 14, height: 16)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain).help("Cerrar \(document.url.lastPathComponent)")
        }
        .padding(.horizontal, 14).frame(height: 39)
        .background(selected ? Theme.background : Theme.bar)
        .overlay(alignment: .top) { if selected { Rectangle().fill(Theme.blue.opacity(0.8)).frame(height: 2) } }
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.border).frame(width: 1) }
        .help(document.url.path)
    }
}

private struct CommandSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var project: CodeProject
    let save: (CodeProject) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(project.name).font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                Text("Comando").foregroundStyle(.secondary)
                TextField("npm run dev", text: $project.command)
                    .font(.system(size: 12, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Spacer()
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Guardar") { save(project)
                dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 460)
    }
}
