import SwiftUI

struct WorkspaceView: View {
    @Bindable var controller: WorkspaceController

    var body: some View {
        VStack(spacing: 0) {
            if let workspace = controller.workspace, let url = controller.workspaceURL {
                if controller.isReadOnly { readOnlyBanner }
                HStack(spacing: 0) {
                    ProjectRail(controller: controller)
                    HSplitView {
                        if controller.sidebarVisible {
                            WorkspaceSidebar(controller: controller, workspace: workspace, url: url).id(url)
                                .frame(minWidth: 270, idealWidth: 270, maxWidth: 360)
                                .background(SidebarWidthPersistence())
                        }
                        VSplitView {
                            editorArea
                                .frame(minWidth: 520, maxWidth: .infinity, minHeight: 240, maxHeight: .infinity)
                            if !controller.workflowVisible, let document = controller.selectedDocument,
                               document.language == "SQL", controller.database.resultsVisible,
                               document.sqlExecution.isRunning || document.sqlExecution.error != nil || !document.sqlExecution.results
                               .isEmpty {
                                SQLResultsPanel(execution: document.sqlExecution) { controller.database.resultsVisible = false }
                                    .frame(minHeight: 140, idealHeight: 220, maxHeight: 350)
                            } else if controller.processesVisible && !controller.workflowVisible {
                                ProcessPanel(controller: controller)
                                    .frame(minHeight: 150, idealHeight: 240, maxHeight: 440)
                            }
                        }
                        if controller.agent.visible && !controller.workflowVisible {
                            AgentPanel(controller: controller).frame(minWidth: 300, idealWidth: 350, maxWidth: 460)
                        }
                    }
                }
                EditorStatusBar(document: controller.workflowVisible ? nil : controller.selectedDocument)
            } else {
                WelcomeView(controller: controller)
            }
        }
        .background(Theme.background)
        .tint(Theme.accent)
        .disabled(controller.isRestoringSession)
        .preferredColorScheme(Theme.colorScheme)
        .frame(minWidth: controller.workspace == nil ? 760 : 900, minHeight: controller.workspace == nil ? 420 : 580)
        .toolbar {
            if controller.workspace != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button { if let url = controller.workspaceURL {
                        controller.workflows.configure(url, root: controller.workflowRoot)
                        controller.workflowTabOpen = true
                        controller.workflowVisible = true
                    } } label: {
                        Image(systemName: "point.3.connected.trianglepath.dotted")
                    }.help("Abrir automatización").accessibilityLabel("Abrir automatización")
                }
                ToolbarItem(placement: .primaryAction) {
                    SettingsLink { Image(systemName: "gearshape") }
                        .help("Configuración")
                        .accessibilityLabel("Configuración")
                }
                if !controller.workflowVisible {
                    ToolbarItem(placement: .primaryAction) {
                        Button { controller.agent.visible.toggle() } label: { Image(systemName: "sparkles") }
                            .help("Mostrar Codex").accessibilityLabel("Mostrar Codex")
                            .disabled(controller.isReadOnly)
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(action: controller.startAll) { Image(systemName: "play.fill") }
                        .help("Iniciar proyecto")
                        .disabled(controller.runnableProjects.isEmpty || controller.runnableProjects
                            .allSatisfy { controller.runner.runs[$0.id]?.status.active == true })
                }
                if !controller.workflowVisible {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            if controller.selectedDocument?.language == "SQL" { controller.database.resultsVisible.toggle() }
                            else { controller.processesVisible.toggle() }
                        } label: { Image(systemName: "rectangle.bottomthird.inset.filled") }
                            .help("Mostrar procesos")
                    }
                }
            }
        }
        .sheet(isPresented: Binding(get: { controller.closingProjectURL != nil },
                                    set: { if !$0 { controller.closingProjectURL = nil } })) {
            if let url = controller.closingProjectURL { ProjectCloseSheet(controller: controller, url: url) }
        }
        .sheet(isPresented: $controller.showingProjectWizard) {
            ProjectWizard(controller: controller)
        }
        .sheet(item: $controller.commandProject) { project in
            CommandSheet(project: project) { controller.projects.update($0) }
        }
        .sheet(item: Binding(get: { controller.database.editingConnection },
                             set: { controller.database.editingConnection = $0 })) { connection in
            ConnectionSheet(connection: connection, controller: controller)
        }
        // Muestra el primero de la cola, no el último: el primero suele ser la causa y
        // el resto la consecuencia. «Aceptar» pasa al siguiente si hay más.
        .alert("No se pudo completar",
               isPresented: Binding(get: { controller.errors.current != nil },
                                    set: { if !$0 { controller.errors.dismissFirst() } })) {
            Button(controller.errors.pending == 0 ? "Aceptar" : "Siguiente") {
                controller.errors.dismissFirst()
            }
            if controller.errors.pending > 0 {
                Button("Descartar todos", role: .cancel) { controller.errors.dismissAll() }
            }
        } message: {
            let pendientes = controller.errors.pending
            Text((controller.errors.current?.message ?? "")
                + (pendientes == 0 ? "" : "\n\n(y \(pendientes) más)"))
        }
        .task { await controller.start() }
    }

    private var editorArea: some View {
        VStack(spacing: 0) {
            if !controller.documents.isEmpty || controller.workflowTabOpen {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(controller.documents) { document in
                            WorkspaceEditorTab(title: document.url.lastPathComponent,
                                               icon: Image(nsImage: FileIcons.file(document.url)),
                                               tooltip: document.url.path,
                                               isDirty: document.isDirty,
                                               selected: !controller.workflowVisible && controller.selectedDocumentID == document.id,
                                               select: { controller.selectedDocumentID = document.id },
                                               close: { controller.closeDocument(document) })
                        }
                        if controller.workflowTabOpen {
                            WorkspaceEditorTab(title: controller.workflows.selected?.name ?? "Automatización",
                                               icon: Image(systemName: "point.3.connected.trianglepath.dotted"),
                                               tooltip: controller.workflows.selected?.name ?? "Automatización",
                                               selected: controller.workflowVisible,
                                               select: { controller.workflowVisible = true },
                                               close: {
                                                   controller.workflowVisible = false
                                                   controller.workflowTabOpen = false
                                               })
                        }
                    }.padding(.horizontal, 9).padding(.vertical, 7)
                }.background(Theme.bar)
                Rectangle().fill(Theme.border).frame(height: 1)
            }
            if controller.workflowVisible, let url = controller.workspaceURL {
                WorkflowView(controller: controller, workspaceURL: url)
            } else { editor }
        }
        .onChange(of: controller.selectedDocumentID) { old, new in
            if new != old, new != nil { controller.workflowVisible = false }
        }
        .onChange(of: controller.workspaceURL) { _, _ in
            controller.workflowVisible = false
            controller.workflowTabOpen = false
        }
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
            Button("Confiar") { controller.session.trustCurrent() }
                .controlSize(.small)
        }
        .padding(.horizontal, 16).frame(height: 32)
        .background(Color.orange.opacity(0.12))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private var editor: some View {
        VStack(spacing: 0) {
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
                        Button("Recargar") { controller.files.reload(document) }
                    }.font(.system(size: 11)).padding(.horizontal, 18).padding(.vertical, 6)
                }
                if document.language == "SQL" { SQLToolbar(document: document, controller: controller) }
                CodeEditor(document: document, theme: AppSettings.shared.theme).id(document.id)
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

private struct WorkspaceEditorTab: View {
    let title: String
    let icon: Image
    let tooltip: String
    var isDirty = false
    let selected: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var hovered = false
    @State private var closeHovered = false
    @FocusState private var closeFocused: Bool

    private var showsDirtyIndicator: Bool { isDirty && !closeHovered && !closeFocused }
    private var showsClose: Bool { selected || hovered || closeFocused || isDirty }

    var body: some View {
        HStack(spacing: 4) {
            Button(action: select) {
                HStack(spacing: 7) {
                    icon
                        .resizable().scaledToFit().frame(width: 14, height: 14)
                        .opacity(selected ? 1 : 0.75)
                        .accessibilityHidden(true)
                    Text(title)
                        .font(.system(size: 12, weight: selected ? .medium : .regular))
                        .lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(selected ? .primary : .secondary)
                }
                .padding(.leading, 10).padding(.trailing, 2)
                .frame(maxWidth: 240).frame(height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
            Button(action: close) {
                Image(systemName: showsDirtyIndicator ? "circle.fill" : "xmark")
                    .font(.system(size: showsDirtyIndicator ? 6 : 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .opacity(showsClose ? 1 : 0)
                    .frame(width: 24, height: 24)
                    .background(Theme.surfaceInk.opacity(closeHovered ? 0.07 : 0), in: RoundedRectangle(cornerRadius: 4))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focused($closeFocused)
            .onHover { closeHovered = $0 }
            .accessibilityLabel("Cerrar \(title)")
            .accessibilityValue(isDirty ? "Cambios sin guardar" : "")
            .help("Cerrar \(title)" + (isDirty ? " · cambios sin guardar" : ""))
        }
        .padding(.trailing, 4).fixedSize(horizontal: true, vertical: false)
        .background(Theme.surfaceInk.opacity(selected ? 0.09 : hovered ? 0.025 : 0), in: RoundedRectangle(cornerRadius: 7))
        .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.surfaceInk.opacity(selected ? 0.045 : 0)) }
        .shadow(color: .black.opacity(selected ? 0.14 : 0), radius: 1, y: 1)
        .onHover { hovered = $0 }
        .help(tooltip)
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
