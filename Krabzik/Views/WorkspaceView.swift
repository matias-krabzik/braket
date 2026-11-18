import CoreGraphics
import SwiftUI
import UniformTypeIdentifiers

struct WorkspaceView: View {
    @Bindable var controller: WorkspaceController
    @State private var draggedTabID: URL?
    @State private var emptySQLExecution = SQLExecution()

    private var showsSQLResults: Bool {
        guard !controller.workflowVisible, controller.database.resultsVisible else { return false }
        return true
    }

    private var sqlExecution: SQLExecution {
        guard let document = controller.sqlResultsDocument else { return emptySQLExecution }
        return document.sqlExecution
    }

    var body: some View {
        VStack(spacing: 0) {
            if let workspace = controller.workspace, let url = controller.workspaceURL {
                if controller.isReadOnly { readOnlyBanner }
                HStack(spacing: 0) {
                    WorkspaceActivityBar(controller: controller).zIndex(1)
                    WorkspaceVerticalSplit(showsBottom: showsSQLResults ||
                                           (controller.selectedProcessesVisible && !controller.workflowVisible && !controller
                                           .outputVisible),
                                           isResults: showsSQLResults) {
                        HSplitView {
                            if controller.sidebarVisible {
                                Group {
                                    if controller.database.browserShowsDatabases { DatabaseExplorer(controller: controller) }
                                    else { WorkspaceSidebar(controller: controller, workspace: workspace, url: url).id(url) }
                                }
                                .frame(minWidth: 230, idealWidth: controller.database.browserShowsDatabases ? 380 : 270, maxWidth: 420)
                                .clipped()
                                .background(SidebarWidthPersistence(databases: controller.database.browserShowsDatabases)
                                    .id(controller.database.browserShowsDatabases))
                            }
                            editorArea.frame(minWidth: 420, maxWidth: .infinity, minHeight: 180, maxHeight: .infinity)
                        }
                    } bottom: {
                        if showsSQLResults {
                            SQLResultsPanel(execution: sqlExecution, controller: controller) {
                                controller.database.resultsVisible = false
                                controller.outputVisible = false
                                controller.processesVisible = false
                            }.frame(minHeight: 220, idealHeight: 360, maxHeight: .infinity)
                        } else if controller.selectedProcessesVisible && !controller.workflowVisible && !controller.outputVisible {
                            ProcessPanel(controller: controller).frame(minHeight: 150, idealHeight: 240, maxHeight: 440)
                        }
                    }
                }
                EditorStatusBar(document: controller.workflowVisible ? nil : controller.selectedDocument,
                                settings: controller.settings)
            } else if !controller.documents.isEmpty {
                editorArea
                EditorStatusBar(document: controller.selectedDocument, settings: controller.settings)
            } else {
                WelcomeView(controller: controller)
            }
        }
        .background(Theme.background)
        .tint(Theme.accent)
        .font(Theme.interfaceFont())
        .disabled(controller.isRestoringSession)
        .preferredColorScheme(Theme.colorScheme)
        .qaCommands(AppMenuCommands(controller: controller).all)
        .frame(minWidth: controller.workspace == nil && controller.documents.isEmpty ? 760 : 900,
               minHeight: controller.workspace == nil && controller.documents.isEmpty ? 420 : 580)
        .toolbar {
            if controller.workspace != nil {
                if #available(macOS 26, *) {
                    projectToolbarItem.sharedBackgroundVisibility(.hidden)
                    ToolbarSpacer(.flexible, placement: .primaryAction)
                } else {
                    projectToolbarItem
                    ToolbarItem(placement: .principal) { Spacer() }
                }
                if #available(macOS 26, *) {
                    settingsToolbarItem.sharedBackgroundVisibility(.hidden)
                } else {
                    settingsToolbarItem
                }
            }
        }
        .sheet(isPresented: Binding(get: { controller.closingProjectURL != nil },
                                    set: { if !$0 { controller.closingProjectURL = nil } })) {
            if let url = controller.closingProjectURL { ProjectCloseSheet(controller: controller, url: url) }
        }
        .sheet(isPresented: $controller.showingProjectSettings) {
            if let workspace = controller.workspace, let url = controller.workspaceURL {
                ProjectSettingsModal(controller: controller, workspace: workspace, url: url).id(url)
            }
        }
        .sheet(isPresented: $controller.showingSettings) {
            SettingsView(settings: controller.settings, controller: controller, showsDone: true)
        }
        .sheet(isPresented: $controller.showingProjectWizard) {
            ProjectWizard(controller: controller)
        }
        .sheet(item: $controller.commandProject) { project in
            CommandSheet(project: project) { controller.projects.update($0) }
        }
        .sheet(isPresented: Binding(get: { controller.database.showingConnections },
                                    set: { controller.database.showingConnections = $0 })) {
            ConnectionsSettingsView(controller: controller, showsDone: true).frame(width: 680, height: 560)
        }
        .sheet(item: Binding(get: { controller.database.editingConnection },
                             set: { controller.database.editingConnection = $0 })) { connection in
            ConnectionSheet(connection: connection, controller: controller)
        }
        .sheet(item: Binding(get: {
            controller.database.schema.selectionHosts.isEmpty ? controller.database.schema.choosing : nil
        },
                             set: { controller.database.schema.choosing = $0 })) { connection in
            DatabaseSelectionSheet(connection: connection, database: controller.database)
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

    private var settingsToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button { controller.showingSettings = true } label: {
                Image(systemName: "gearshape").frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Configuración")
            .accessibilityLabel("Configuración")
        }
    }

    private var projectToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            HStack(spacing: 10) {
                Text("Braket").font(Theme.interfaceFont().weight(.semibold))
                ProjectPicker(controller: controller)
            }
        }
    }

    private var editorArea: some View {
        VStack(spacing: 0) {
            if !controller.documents.isEmpty || controller.workflowTabOpen {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(controller.documents) { document in
                            WorkspaceEditorTab(title: document.url.lastPathComponent,
                                               icon: Image(nsImage: FileIcons.file(document.url)),
                                               tooltip: document.isDraft ? "Borrador · sin guardar" : document.url.path,
                                               isDirty: document.isDirty,
                                               selected: !controller.workflowVisible && controller
                                               .selectedDocumentID == document.id,
                                               select: { controller.selectedDocumentID = document.id },
                                               close: { controller.closeDocument(document) },
                                               drag: {
                                                   draggedTabID = document.id
                                                   return NSItemProvider(object: document.id.absoluteString as NSString)
                                               })
                                .onDrop(of: [UTType.plainText.identifier], isTargeted: nil) { _ in
                                    guard let source = draggedTabID else { return false }
                                    controller.moveTab(source, before: document.id)
                                    draggedTabID = nil
                                    return true
                                }
                                .contextMenu {
                                    Button("Cerrar") { controller.closeDocument(document) }
                                    Button("Cerrar pestañas a la derecha") {
                                        let tabs = controller.documents
                                        guard let index = tabs.firstIndex(where: { $0.id == document.id }) else { return }
                                        controller.closeTabs(Array(tabs.dropFirst(index + 1)), closeWorkflow: controller.workflowTabOpen)
                                    }
                                    Button("Cerrar pestañas a la izquierda") {
                                        let tabs = controller.documents
                                        guard let index = tabs.firstIndex(where: { $0.id == document.id }) else { return }
                                        controller.closeTabs(Array(tabs.prefix(index)))
                                    }
                                    Button("Cerrar las demás") {
                                        controller.closeTabs(controller.documents.filter { $0.id != document.id },
                                                             closeWorkflow: controller.workflowTabOpen)
                                    }
                                    Button("Cerrar todas") {
                                        controller.closeTabs(controller.documents, closeWorkflow: controller.workflowTabOpen)
                                    }
                                    Divider()
                                    Button("Renombrar…") { controller.renameFile(document.url) }.disabled(document.isDraft)
                                        .disabled(controller.isReadOnly)
                                }
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
                            .contextMenu {
                                Button("Cerrar") {
                                    controller.workflowVisible = false
                                    controller.workflowTabOpen = false
                                }
                                Button("Cerrar pestañas a la izquierda") { controller.closeTabs(controller.documents) }
                                Button("Cerrar las demás") { controller.closeTabs(controller.documents) }
                                Button("Cerrar todas") { controller.closeTabs(controller.documents, closeWorkflow: true) }
                            }
                        }
                    }.padding(.horizontal, 9).padding(.vertical, 7)
                }.background(Theme.bar)
                Rectangle().fill(Theme.border).frame(height: 1)
            }
            if controller.workflowVisible, let url = controller.workspaceURL {
                WorkflowView(controller: controller, workspaceURL: url)
            } else { editor }
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
            Image(systemName: "lock").font(.system(size: Theme.zoom(11)))
            Text("Proyecto no confiable · solo lectura")
                .font(.system(size: Theme.zoom(11), weight: .medium))
            Text("No se ejecutan procesos ni se conectan bases de datos.")
                .font(.system(size: Theme.zoom(11))).foregroundStyle(.secondary)
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
                if document.language != "SQL" {
                    HStack(spacing: 7) {
                        Text(document.isDraft ? "Borrador · " + document.url.lastPathComponent : breadcrumb(document.url)).lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        if isMarkdown(document) { markdownModeControls(document) }
                    }
                    .font(.system(size: Theme.zoom(11))).foregroundStyle(.secondary)
                    .padding(.horizontal, 20).frame(height: 31)
                    .background(Theme.background)
                }
                if document.hasExternalChange {
                    HStack {
                        Text("El archivo cambió en disco.").foregroundStyle(.orange)
                        Spacer()
                        Button("Recargar") { controller.files.reload(document) }
                    }.font(.system(size: Theme.zoom(11))).padding(.horizontal, 18).padding(.vertical, 6)
                }
                if document.language == "SQL" { SQLToolbar(document: document, controller: controller) }
                ZStack(alignment: .topTrailing) {
                    if document.pixelArt != nil {
                        PixelArtEditorView(document: document, readOnly: controller.isReadOnly,
                                           exportPNG: controller.files.exportPixelPNG,
                                           reportError: { controller.errors.report($0) })
                            .id(document.id)
                    } else if let image = document.previewImage {
                        Image(nsImage: image)
                            .resizable().interpolation(.high).scaledToFit()
                            .padding(20)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .accessibilityLabel("Vista previa de \(document.url.lastPathComponent)")
                    } else if isMarkdown(document) {
                        markdownContent(document)
                    } else {
                        CodeEditor(document: document, theme: Theme.settings.theme, uiScale: controller.settings.codeFontScale,
                                   wrapsLines: controller.settings.wrapLines, readOnly: controller.isReadOnly,
                                   options: controller.settings.editorOptions, completion: { text, position in
                                       let connection = controller.connections.selected(for: document)
                                       let database = connection.map { controller.database.state($0.id).currentDatabase } ?? ""
                                       return controller.database.schema.completions(connection: connection, database: database,
                                                                                     text: text, position: position)
                                   }).id(document.id)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    if document.search.visible, document.pixelArt == nil, document.previewImage == nil {
                        EditorSearchBar(document: document, readOnly: controller.isReadOnly, search: document.search)
                            .id(document.id)
                            .frame(maxWidth: Theme.zoom(620))
                            .padding(12)
                    }
                }
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "curlybraces").font(.system(size: Theme.zoom(43), weight: .ultraLight)).foregroundStyle(.quaternary)
                    Text(controller.workspace?.name ?? "").font(.system(size: Theme.zoom(13))).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func isMarkdown(_ document: EditorDocument) -> Bool {
        ["md", "markdown", "mdx"].contains(document.url.pathExtension.lowercased())
    }

    private func markdownModeControls(_ document: EditorDocument) -> some View {
        HStack(spacing: 2) {
            markdownButton("Edición", icon: "chevron.left.forwardslash.chevron.right", mode: .edit, document: document)
            markdownButton("Dos paneles", icon: "rectangle.split.2x1", mode: .split, document: document)
            markdownButton("Vista previa", icon: "doc.richtext", mode: .preview, document: document)
        }
        .padding(2)
        .background(Theme.bar, in: RoundedRectangle(cornerRadius: 6))
    }

    private func markdownButton(_ title: String, icon: String, mode: EditorDocument.MarkdownMode,
                                document: EditorDocument) -> some View {
        Button { document.markdownMode = mode } label: {
            Image(systemName: icon).frame(width: 25, height: 20)
                .background(document.markdownMode == mode ? Theme.accent.opacity(0.18) : .clear,
                            in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .foregroundStyle(document.markdownMode == mode ? Theme.accent : .secondary)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(document.markdownMode == mode ? [.isSelected] : [])
    }

    @ViewBuilder private func markdownContent(_ document: EditorDocument) -> some View {
        let roots = controller.workspace?.projects.compactMap { project in
            controller.workspaceURL.map { project.directory(relativeTo: $0).resolvingSymlinksInPath() }
        } ?? []
        switch document.markdownMode {
        case .edit:
            CodeEditor(document: document, theme: Theme.settings.theme, uiScale: controller.settings.codeFontScale,
                       wrapsLines: controller.settings.wrapLines, readOnly: controller.isReadOnly,
                       options: controller.settings.editorOptions).id(document.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .preview:
            MarkdownPreview(document: document, projectRoots: roots).id(document.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .split:
            HSplitView {
                CodeEditor(document: document, theme: Theme.settings.theme, uiScale: controller.settings.codeFontScale,
                           wrapsLines: controller.settings.wrapLines, readOnly: controller.isReadOnly,
                           options: controller.settings.editorOptions).id(document.id)
                    .frame(minWidth: 230, maxWidth: .infinity, maxHeight: .infinity)
                MarkdownPreview(document: document, projectRoots: roots).id(document.id)
                    .frame(minWidth: 230, maxWidth: .infinity, maxHeight: .infinity)
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

private struct PixelArtEditorView: View {
    private struct ToolItem: Identifiable {
        let name: String
        let label: String
        let icon: String
        var id: String { name }
    }

    private let availableTools = [
        ToolItem(name: "pencil", label: "Lápiz", icon: "pencil.tip"),
        ToolItem(name: "eraser", label: "Borrador", icon: "eraser"),
        ToolItem(name: "eyedropper", label: "Cuentagotas", icon: "eyedropper"),
        ToolItem(name: "fill", label: "Relleno", icon: "paintbrush.pointed"),
        ToolItem(name: "selection", label: "Selección rectangular", icon: "selection.pin.in.out"),
        ToolItem(name: "lasso", label: "Lazo", icon: "lasso"),
        ToolItem(name: "line", label: "Línea", icon: "line.diagonal"),
        ToolItem(name: "rectangle", label: "Rectángulo", icon: "rectangle"),
        ToolItem(name: "ellipse", label: "Elipse", icon: "circle"),
        ToolItem(name: "hand", label: "Mano", icon: "hand.draw"),
        ToolItem(name: "zoom", label: "Zoom", icon: "plus.magnifyingglass")
    ]
    private let layerColumnWidth: CGFloat = 260
    private let frameColumnWidth: CGFloat = 64
    @Bindable var document: EditorDocument
    let readOnly: Bool
    let exportPNG: () -> Void
    let reportError: (Error) -> Void
    @State private var renderedImage: NSImage?
    @State private var renderedBitmap: PixelBitmap?
    @State private var renderedRevision = -1
    @State private var stroke: [PixelWrite] = []
    @State private var committedStroke: [PixelWrite] = []
    @State private var lastStrokePoint: PixelWrite?
    @State private var lassoPoints: [PixelPoint] = []
    @State private var selectionDraft: PixelSelection?
    @State private var panOffset = CGSize.zero
    @State private var panStart = CGSize.zero
    @State private var isPlaying = false
    private var onionPrevious: Int { art?.editor.onionPrevious ?? 2 }
    private var onionNext: Int { art?.editor.onionNext ?? 1 }
    @State private var onionImages: [(Int, NSImage)] = []
    @State private var inspectorVisible = true
    @State private var compactInspectorVisible = false
    @State private var codexExpanded = true
    @State private var colorSheetVisible = false
    @State private var colorHex = "#000000"

    private var art: PixelArtDocument? { document.pixelArt }
    private var activeLayer: PixelLayer? {
        guard let art else { return nil }
        return art.state.layers.first { $0.id == art.editor.activeLayerID }
    }
    private var scale: CGFloat { CGFloat(art?.editor.zoomPercent ?? 100) / 100 }
    private var activeTool: ToolItem { availableTools.first(where: { $0.name == art?.editor.tool }) ?? availableTools[0] }

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 780
            VStack(spacing: 0) {
                toolbar(compact: compact)
                HStack(spacing: 0) {
                    HStack(spacing: 0) {
                        tools
                        VStack(spacing: 0) {
                            canvas
                            timeline
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if !compact && inspectorVisible { inspector }
                }
                .overlay(alignment: .trailing) {
                    if compact && compactInspectorVisible {
                        inspector.shadow(color: .black.opacity(0.4), radius: 16)
                    }
                }
            }
        }
        .task(id: document.previewRevision) {
            let revision = document.previewRevision
            guard let art, let frame = art.editor.activeFrameID else { renderedImage = nil
            return }
            let state = art.state
            let bitmap = await Task.detached(priority: .userInitiated) {
                PixelArtRenderer.render(state, frame: frame)
            }.value
            guard !Task.isCancelled, revision == document.previewRevision else { return }
            renderedBitmap = bitmap
            renderedRevision = revision
            renderedImage = Self.image(from: bitmap)
            committedStroke.removeAll()
        }
        .task(id: "\(document.previewRevision)-\(art?.editor.onionSkin ?? false)-\(onionPrevious)-\(onionNext)") {
            guard let art, art.editor.onionSkin, let frame = art.editor.activeFrameID else { onionImages = []
            return }
            let state = art.state, previous = onionPrevious, next = onionNext
            let bitmaps = await Task.detached(priority: .userInitiated) {
                PixelOnionSkin.previews(state, frame: frame, previous: previous, next: next)
            }.value
            guard !Task.isCancelled else { return }
            onionImages = bitmaps.compactMap { offset, bitmap in Self.image(from: bitmap).map { (offset, $0) } }
        }
        .task(id: isPlaying) {
            while isPlaying && !Task.isCancelled {
                guard let art, let current = art.editor.activeFrameID,
                      let index = art.state.frameIndex(current), art.state.frames.count > 1 else {
                    isPlaying = false
                    break
                }
                let duration = art.state.frames[index].duration
                try? await Task.sleep(for: .milliseconds(duration))
                guard isPlaying, !Task.isCancelled, let nextArt = self.art,
                      let nextIndex = nextArt.state.frameIndex(current) else { continue }
                let next = nextArt.state.frames[(nextIndex + 1) % nextArt.state.frames.count]
                document.updatePixelEditor { $0.activeFrameID = next.id }
            }
        }
        .sheet(isPresented: $colorSheetVisible) { colorChooser }
    }

    private func toolbar(compact: Bool) -> some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(availableTools) { item in
                    Button(item.label) { selectTool(item.name) }
                }
            } label: {
                Label(activeTool.label, systemImage: activeTool.icon)
            }
            .frame(minWidth: 96)
            .buttonStyle(.bordered)
            Menu {
                ForEach([1, 2, 4, 8, 16, 32, 64], id: \.self) { size in
                    Button("\(size) px") { document.updatePixelEditor { $0.brushSize = size } }
                }
            } label: { Text("\(art?.editor.brushSize ?? 1) px") }
            .disabled(readOnly || art?.isReadOnly == true)
            Button { openColorChooser() } label: {
                RoundedRectangle(cornerRadius: 4).fill(activeColor)
                    .frame(width: 28, height: 18)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.primary.opacity(0.45)))
            }
            .help("Elegir color libre")
            .accessibilityLabel("Color activo")
            Button { document.updatePixelEditor { $0.showsGrid.toggle() } } label: {
                Image(systemName: "square.grid.3x3")
            }.help("Alternar cuadrícula")
                .foregroundStyle(art?.editor.showsGrid == true ? Theme.accent : Color.primary)
            if art?.editor.selection != nil {
                Button("Deseleccionar") { document.updatePixelEditor { $0.selection = nil } }
                    .help("Quitar selección")
            }
            Button { resizeCanvas() } label: {
                Label("Lienzo…", systemImage: "square.dashed")
            }
            .help("Cambiar tamaño del lienzo")
            .disabled(readOnly || art?.isReadOnly == true)
            Divider().frame(height: 20)
            Button { navigateHistory(redo: false) } label: {
                Image(systemName: "arrow.uturn.backward")
            }.help("Deshacer").disabled(readOnly || art?.isReadOnly == true)
            Button { navigateHistory(redo: true) } label: {
                Image(systemName: "arrow.uturn.forward")
            }.help("Rehacer").disabled(readOnly || art?.isReadOnly == true)
            Spacer(minLength: 6)
            Button { if compact { compactInspectorVisible.toggle() } else { inspectorVisible.toggle() } } label: {
                Label("Codex", systemImage: "sparkles")
            }.buttonStyle(.borderedProminent).tint(Theme.accent)
                .help("Mostrar inspector de paleta y Codex")
            Button("Exportar…", action: exportPNG).buttonStyle(.bordered)
        }
        .buttonStyle(.borderless)
        .font(.system(size: Theme.zoom(12)))
        .padding(.horizontal, 12).frame(height: 42)
        .background(Theme.bar)
    }

    private var tools: some View {
        ScrollView(.vertical, showsIndicators: false) {
        VStack(spacing: 8) {
            tool("pencil", icon: "pencil.tip", label: "Lápiz")
            tool("eraser", icon: "eraser", label: "Borrador")
            tool("eyedropper", icon: "eyedropper", label: "Cuentagotas")
            tool("fill", icon: "paintbrush.pointed", label: "Relleno")
            tool("selection", icon: "selection.pin.in.out", label: "Selección rectangular")
            tool("lasso", icon: "lasso", label: "Lazo")
            tool("line", icon: "line.diagonal", label: "Línea")
            tool("rectangle", icon: "rectangle", label: "Rectángulo")
            tool("ellipse", icon: "circle", label: "Elipse")
            tool("hand", icon: "hand.draw", label: "Mano")
            tool("zoom", icon: "plus.magnifyingglass", label: "Zoom")
        }
        .frame(width: 48).padding(.vertical, 12)
        }
        .frame(width: 48)
        .background(Theme.bar)
    }

    private func tool(_ name: String, icon: String, label: String) -> some View {
        let selected = art?.editor.tool == name
        return Button { selectTool(name) } label: {
            Image(systemName: icon)
                .frame(width: 32, height: 32)
                .background(selected ? Theme.accent.opacity(0.28) : .clear,
                            in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke(selected ? Theme.accent : .clear, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(label).accessibilityLabel(label)
        .disabled(name != "hand" && (readOnly || art?.isReadOnly == true))
    }

    private var canvas: some View {
        VStack(spacing: 0) {
        ScrollView([.horizontal, .vertical]) {
            if let image = renderedImage, let art {
                ZStack {
                    Image(nsImage: checkerboardTile)
                        .interpolation(.none)
                        .resizable(resizingMode: .tile)
                    ZStack {
                        Image(nsImage: image)
                            .interpolation(.none)
                            .resizable()
                        if art.editor.onionSkin && !isPlaying {
                            ForEach(onionImages.indices, id: \.self) { index in
                                let item = onionImages[index]
                                Image(nsImage: item.1).interpolation(.none).resizable()
                                    .colorMultiply(item.0 < 0 ? .purple : .orange)
                                    .opacity(abs(item.0) == 1 ? 0.28 : 0.14)
                                    .allowsHitTesting(false)
                            }
                        }
                        strokeOverlay(committedStroke, erasing: false, palette: art.state.palette)
                        strokeOverlay(committedStroke, erasing: true, palette: art.state.palette)
                        strokeOverlay(stroke, erasing: false, palette: art.state.palette)
                        strokeOverlay(stroke, erasing: true, palette: art.state.palette)
                    }
                    .compositingGroup()
                    if art.editor.showsGrid { gridOverlay(width: art.state.width, height: art.state.height) }
                    if let selection = selectionDraft ?? art.editor.selection { selectionOverlay(selection) }
                }
                    .frame(width: CGFloat(art.state.width) * scale,
                           height: CGFloat(art.state.height) * scale)
                    .overlay(Rectangle().stroke(Color.primary.opacity(0.45), lineWidth: 1))
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged(handleCanvasDrag)
                        .onEnded(endCanvasDrag))
                    .offset(panOffset)
                    .padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView("Componiendo imagen…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(red: 0.12, green: 0.13, blue: 0.16))
        .accessibilityLabel("Lienzo pixel art")
        HStack(spacing: 8) {
            if let art { Text("\(art.state.width) × \(art.state.height) px") }
            Spacer()
            Button { zoom(by: 0.5) } label: { Image(systemName: "minus.magnifyingglass") }
            Text("\(art?.editor.zoomPercent ?? 100) %").monospacedDigit().frame(minWidth: 55)
            Button { zoom(by: 2) } label: { Image(systemName: "plus.magnifyingglass") }
        }
        .buttonStyle(.borderless).font(.system(size: Theme.zoom(10)))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12).frame(height: 30)
        .background(Theme.bar)
        }
    }

    private var checkerboardTile: NSImage {
        // Cada celda del tablero representa un píxel del documento al zoom actual.
        let cell = scale
        let side = cell * 2
        let tile = NSImage(size: NSSize(width: side, height: side))
        tile.lockFocus()
        NSColor(calibratedWhite: 0.78, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: side, height: side)).fill()
        NSColor(calibratedWhite: 0.9, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: cell, height: cell)).fill()
        NSBezierPath(rect: NSRect(x: cell, y: cell, width: cell, height: cell)).fill()
        tile.unlockFocus()
        return tile
    }

    private func gridOverlay(width: Int, height: Int) -> some View {
        Canvas { context, _ in
            guard scale >= 4 else { return }
            var lines = Path()
            for x in 1..<width {
                let position = CGFloat(x) * scale
                lines.move(to: CGPoint(x: position, y: 0))
                lines.addLine(to: CGPoint(x: position, y: CGFloat(height) * scale))
            }
            for y in 1..<height {
                let position = CGFloat(y) * scale
                lines.move(to: CGPoint(x: 0, y: position))
                lines.addLine(to: CGPoint(x: CGFloat(width) * scale, y: position))
            }
            context.stroke(lines, with: .color(.black.opacity(0.28)), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
    }

    private func selectionOverlay(_ selection: PixelSelection) -> some View {
        Canvas { context, _ in
            var outline = Path()
            for (coord, tile) in selection.tiles {
                for localY in 0..<PxaTile.side {
                    for localX in 0..<PxaTile.side where tile[localX, localY] {
                        let x = coord.x * PxaTile.side + localX
                        let y = coord.y * PxaTile.side + localY
                        let left = CGFloat(x) * scale, top = CGFloat(y) * scale
                        if !selection.contains(x: x - 1, y: y) {
                            outline.move(to: CGPoint(x: left, y: top))
                            outline.addLine(to: CGPoint(x: left, y: top + scale))
                        }
                        if !selection.contains(x: x + 1, y: y) {
                            outline.move(to: CGPoint(x: left + scale, y: top))
                            outline.addLine(to: CGPoint(x: left + scale, y: top + scale))
                        }
                        if !selection.contains(x: x, y: y - 1) {
                            outline.move(to: CGPoint(x: left, y: top))
                            outline.addLine(to: CGPoint(x: left + scale, y: top))
                        }
                        if !selection.contains(x: x, y: y + 1) {
                            outline.move(to: CGPoint(x: left, y: top + scale))
                            outline.addLine(to: CGPoint(x: left + scale, y: top + scale))
                        }
                    }
                }
            }
            context.stroke(outline, with: .color(Theme.accent), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
        }
        .allowsHitTesting(false)
    }

    private func strokeOverlay(_ writes: [PixelWrite], erasing: Bool, palette: PixelPalette) -> some View {
        Canvas { context, _ in
            var drawn = Set<Int>()
            for write in writes.reversed() {
                let isEraser: Bool
                let color: Color
                switch write.value {
                case .empty:
                    isEraser = true
                    color = .white
                case .free(let rgba):
                    isEraser = false
                    color = Self.color(rgba)
                case .linked(let id):
                    isEraser = false
                    color = Self.color(palette.entry(id)?.color ?? PixelRGBA(0, 0, 0))
                }
                guard isEraser == erasing, drawn.insert(write.y * (art?.state.width ?? 0) + write.x).inserted else {
                    continue
                }
                context.fill(Path(CGRect(x: CGFloat(write.x) * scale, y: CGFloat(write.y) * scale,
                                         width: scale, height: scale)), with: .color(color))
            }
        }
        .blendMode(erasing ? .destinationOut : .normal)
        .allowsHitTesting(false)
    }

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                Button { selectFrame(at: 0) } label: { Image(systemName: "backward.end.fill") }
                    .help("Primer fotograma")
                Button { stepFrame(by: -1) } label: { Image(systemName: "backward.fill") }
                    .help("Fotograma anterior")
                Button { isPlaying.toggle() } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                }.help(isPlaying ? "Pausar" : "Reproducir")
                Button { stepFrame(by: 1) } label: { Image(systemName: "forward.fill") }
                    .help("Fotograma siguiente")
                Button { selectFrame(at: (art?.state.frames.count ?? 1) - 1) } label: {
                    Image(systemName: "forward.end.fill")
                }.help("Último fotograma")
                Divider().frame(height: 18)
                Text("Animación").foregroundStyle(.secondary)
                Menu {
                    ForEach([4, 8, 12, 24], id: \.self) { fps in
                        Button("\(fps) fps") { setFPS(fps) }
                    }
                } label: { Text("\(activeFPS) fps") }
                .disabled(readOnly || art?.isReadOnly == true)
                Divider().frame(height: 18)
                Toggle("Piel de cebolla", isOn: Binding(get: { art?.editor.onionSkin ?? false },
                                                        set: { value in document.updatePixelEditor { $0.onionSkin = value } }))
                    .toggleStyle(.switch).controlSize(.mini)
                Text("Atrás")
                Picker("Atrás",
                       selection: Binding(get: { onionPrevious },
                                          set: { value in document.updatePixelEditor { $0.onionPrevious = value } })) {
                    ForEach(0...2, id: \.self) { Text("\($0)").tag($0) }
                }.labelsHidden().pickerStyle(.segmented).frame(width: 88)
                Text("Adelante")
                Picker("Adelante",
                       selection: Binding(get: { onionNext }, set: { value in document.updatePixelEditor { $0.onionNext = value } })) {
                    ForEach(0...2, id: \.self) { Text("\($0)").tag($0) }
                }.labelsHidden().pickerStyle(.segmented).frame(width: 88)
                Spacer(minLength: 8)
                Button { addLayer() } label: { Label("Nueva capa", systemImage: "plus") }
                    .buttonStyle(.bordered)
                    .help("Agregar una capa sobre las demás")
                    .disabled(readOnly || art?.isReadOnly == true)
                if let art, let activeLayer {
                    Menu {
                        layerEditActions(activeLayer, state: art.state)
                    } label: {
                        Label("Editar capa", systemImage: "slider.horizontal.3")
                    }
                    .buttonStyle(.bordered)
                    .help("Editar \(activeLayer.name)")
                    .disabled(readOnly || art.isReadOnly)
                }
                Button { addFrame() } label: { Label("Nuevo fotograma", systemImage: "plus.square.on.square") }
                    .buttonStyle(.bordered)
                    .help("Agregar un fotograma al final")
                    .disabled(readOnly || art?.isReadOnly == true)
            }
            .buttonStyle(.borderless).font(.system(size: Theme.zoom(11)))
            .disabled(art?.state.frames.isEmpty ?? true)
            .padding(.horizontal, 12).frame(height: 38)
            }
            Rectangle().fill(Theme.border).frame(height: 1)
            if let art {
                GeometryReader { geometry in
                ScrollView([.horizontal, .vertical]) {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 0) {
                            Text("CAPAS").font(.caption2).foregroundStyle(.secondary)
                                .frame(width: layerColumnWidth, height: 32, alignment: .leading)
                                .padding(.leading, 10)
                            ForEach(Array(art.state.frames.enumerated()), id: \.element.id) { index, frame in
                                Button { selectFrame(at: index) } label: {
                                    Rectangle()
                                        .fill(art.editor.activeFrameID == frame.id
                                            ? Theme.accent.opacity(0.32) : onionTint(frame.id))
                                        .frame(width: frameColumnWidth, height: 32)
                                        .overlay {
                                            Text("\(index + 1)").allowsHitTesting(false)
                                        }
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Fotograma \(index + 1)")
                            }
                        }
                        .background(Theme.background.opacity(0.4))
                        ForEach(art.state.layers.reversed(), id: \.id) { layer in
                            HStack(spacing: 0) {
                                HStack(spacing: 5) {
                                    Button { toggleLayer(layer, property: "visible") } label: {
                                        RoundedRectangle(cornerRadius: 5)
                                            .fill(Theme.surfaceInk.opacity(0.075))
                                            .frame(width: 30, height: 30)
                                            .overlay {
                                                Image(systemName: layer.visible ? "eye" : "eye.slash")
                                                    .allowsHitTesting(false)
                                            }
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(layer.visible ? "Ocultar \(layer.name)" : "Mostrar \(layer.name)")
                                    .help(layer.visible ? "Ocultar capa" : "Mostrar capa")
                                    Button { toggleLayer(layer, property: "locked") } label: {
                                        RoundedRectangle(cornerRadius: 5)
                                            .fill(Theme.surfaceInk.opacity(0.075))
                                            .frame(width: 30, height: 30)
                                            .overlay {
                                                Image(systemName: layer.locked ? "lock.fill" : "lock.open")
                                                    .allowsHitTesting(false)
                                            }
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(layer.locked ? "Desbloquear \(layer.name)" : "Bloquear \(layer.name)")
                                    .help(layer.locked ? "Desbloquear capa" : "Bloquear capa")
                                    Button { document.updatePixelEditor { $0.activeLayerID = layer.id } } label: {
                                        Rectangle()
                                            .fill(art.editor.activeLayerID == layer.id
                                                ? Theme.accent.opacity(0.17) : Theme.surfaceInk.opacity(0.035))
                                            .frame(height: 30)
                                            .overlay(alignment: .leading) {
                                                Text(layer.name).lineLimit(1)
                                                    .padding(.leading, 5)
                                                    .allowsHitTesting(false)
                                            }
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Seleccionar \(layer.name)")
                                    Menu {
                                        layerEditActions(layer, state: art.state)
                                    } label: {
                                        Text("Editar")
                                            .font(.system(size: Theme.zoom(10)))
                                            .frame(width: 45, height: 30)
                                            .background(Theme.surfaceInk.opacity(0.075), in: RoundedRectangle(cornerRadius: 5))
                                    }
                                    .help("Editar \(layer.name)")
                                    .disabled(readOnly || art.isReadOnly)
                                }
                                .padding(.leading, 8).padding(.trailing, 5)
                                .frame(width: layerColumnWidth + 10, height: 36, alignment: .leading)
                                ForEach(art.state.frames, id: \.id) { frame in
                                    let occupied = frame.cels[layer.id]?.tiles.isEmpty == false
                                    let active = art.editor.activeLayerID == layer.id && art.editor.activeFrameID == frame.id
                                    Button {
                                        activateCell(layer: layer.id, frame: frame.id)
                                    } label: {
                                        Rectangle()
                                            .fill(active ? Theme.accent.opacity(0.32) : onionTint(frame.id))
                                            .frame(width: frameColumnWidth, height: 36)
                                            .overlay {
                                                Text(occupied ? "◆" : "·").allowsHitTesting(false)
                                            }
                                    }
                                    .buttonStyle(.plain)
                                    .help("\(layer.name), fotograma \((art.state.frameIndex(frame.id) ?? 0) + 1)")
                                }
                            }
                            .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
                        }
                    }
                    .frame(minWidth: geometry.size.width, alignment: .leading)
                    .buttonStyle(.plain)
                }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).frame(height: 230)
        .background(Theme.bar)
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Paleta").font(.system(size: Theme.zoom(13), weight: .semibold))
                Spacer()
                Button { addPaletteColor() } label: { Image(systemName: "plus") }
                    .help("Agregar el color activo a la paleta")
                    .disabled(readOnly || art?.isReadOnly == true)
            }
            .padding(.horizontal, 12).frame(height: 37)
            Rectangle().fill(Theme.border).frame(height: 1)
            VStack(alignment: .leading, spacing: 12) {
                if let art {
                    Text("\(art.state.palette.name) · \(art.state.palette.entries.count) colores")
                        .font(.system(size: Theme.zoom(11))).foregroundStyle(.secondary)
                    if art.state.palette.entries.isEmpty {
                        Text("Este documento todavía no tiene paleta")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        ScrollView {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 8), spacing: 5) {
                                ForEach(art.state.palette.entries, id: \.id) { entry in
                                    Button { document.updatePixelEditor { $0.drawColor = .linked(entry.id) } } label: {
                                        RoundedRectangle(cornerRadius: 3).fill(Self.color(entry.color))
                                            .frame(height: 29)
                                            .overlay(RoundedRectangle(cornerRadius: 3)
                                                .stroke(art.editor.drawColor == .linked(entry.id)
                                                    ? Theme.accent : Color.primary.opacity(0.24), lineWidth: 2))
                                            .contentShape(Rectangle())
                                    }.buttonStyle(.plain).help("\(entry.name) · ID \(entry.id)")
                                }
                            }
                        }
                    }
                }
                HStack {
                    Text("Color libre").font(.system(size: Theme.zoom(11)))
                    Spacer()
                    Button { openColorChooser() } label: {
                        RoundedRectangle(cornerRadius: 5).fill(activeColor)
                            .frame(width: 44, height: 22)
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.primary.opacity(0.45)))
                    }
                    .buttonStyle(.plain)
                    .help("Elegir color libre")
                    .accessibilityLabel("Elegir color libre")
                }
                if let art, case .linked = art.editor.drawColor {
                    Label("Paleta vinculada", systemImage: "link")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: 225, alignment: .top)
            Rectangle().fill(Theme.border).frame(height: 1)
            Button { codexExpanded.toggle() } label: {
                HStack {
                    Label("Codex", systemImage: "sparkles")
                        .font(.system(size: Theme.zoom(13), weight: .semibold))
                    Spacer()
                    Image(systemName: codexExpanded ? "chevron.down" : "chevron.right")
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12).frame(height: 37).contentShape(Rectangle())
            }.buttonStyle(.plain)
            Rectangle().fill(Theme.border).frame(height: 1)
            if codexExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    Text("La edición con Codex se integrará en una próxima etapa.")
                        .font(.system(size: Theme.zoom(11))).foregroundStyle(.secondary)
                    Text("Las propuestas aparecerán acá para revisarlas antes de aplicarlas.")
                        .font(.caption).foregroundStyle(.tertiary)
                    Spacer()
                }
                .padding(14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                Spacer(minLength: 0)
            }
        }
        .frame(width: 320).frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.bar)
    }

    private var activeColor: Color {
        Self.color(activeRGBA)
    }

    private var activeRGBA: PixelRGBA {
        guard let art else { return PixelRGBA(0, 0, 0) }
        switch art.editor.drawColor {
        case .free(let rgba): return rgba
        case .linked(let id): return art.state.palette.entry(id)?.color ?? PixelRGBA(0, 0, 0)
        }
    }

    private var colorChooser: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Color libre").font(.headline)
                Spacer()
                Button("Cancelar", action: closeColorChooser)
            }
            HStack {
                TextField("#RRGGBB o #RRGGBBAA", text: $colorHex)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(applyHexColor)
                    .accessibilityLabel("Color hexadecimal")
                Button("Aplicar", action: applyHexColor)
                    .disabled(Self.parseHexColor(colorHex) == nil)
            }
            Text("Colores rápidos").font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(27), spacing: 7), count: 8), spacing: 7) {
                ForEach(Self.quickColors, id: \.self) { hex in
                    if let rgba = Self.parseHexColor(hex) {
                        Button {
                            chooseFreeRGBA(rgba)
                            closeColorChooser()
                        } label: {
                            RoundedRectangle(cornerRadius: 4).fill(Self.color(rgba))
                                .frame(width: 27, height: 27)
                                .overlay(RoundedRectangle(cornerRadius: 4)
                                    .stroke(Color.primary.opacity(0.4)))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(hex)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    private static let quickColors = [
        "#000000", "#FFFFFF", "#7F7F7F", "#C0C0C0", "#9C5D3D", "#EF4444", "#F97316", "#FACC15",
        "#84CC16", "#22C55E", "#14B8A6", "#06B6D4", "#3B82F6", "#6366F1", "#A855F7", "#EC4899"
    ]

    private static func parseHexColor(_ source: String) -> PixelRGBA? {
        let hex = source.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        guard (hex.count == 6 || hex.count == 8), let value = UInt32(hex, radix: 16) else { return nil }
        if hex.count == 6 {
            return PixelRGBA(UInt8((value >> 16) & 0xff), UInt8((value >> 8) & 0xff), UInt8(value & 0xff))
        }
        return PixelRGBA(UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff),
                         UInt8((value >> 8) & 0xff), UInt8(value & 0xff))
    }

    private func openColorChooser() {
        let color = activeRGBA
        colorHex = String(format: "#%02X%02X%02X%02X", color.red, color.green, color.blue, color.alpha)
        colorSheetVisible = true
    }

    private func closeColorChooser() {
        colorSheetVisible = false
    }

    private func applyHexColor() {
        guard let color = Self.parseHexColor(colorHex) else { return }
        chooseFreeRGBA(color)
        closeColorChooser()
    }

    private func chooseFreeRGBA(_ color: PixelRGBA) {
        document.updatePixelEditor { $0.drawColor = .free(color) }
    }

    private var activeFPS: Int {
        guard let art, let id = art.editor.activeFrameID,
              let index = art.state.frameIndex(id) else { return 8 }
        return max(1, Int((1_000.0 / Double(art.state.frames[index].duration)).rounded()))
    }

    private static func color(_ rgba: PixelRGBA) -> Color {
        Color(red: Double(rgba.red) / 255, green: Double(rgba.green) / 255,
              blue: Double(rgba.blue) / 255, opacity: Double(rgba.alpha) / 255)
    }

    private func zoom(by factor: Double) {
        document.updatePixelEditor {
            $0.zoomPercent = min(6_400, max(25, Int(Double($0.zoomPercent) * factor)))
        }
    }

    private func resizeCanvas() {
        guard let art, !readOnly, !art.isReadOnly,
              let options = WorkspacePrompts.pixelArtCanvas(name: nil, width: art.state.width,
                                                            height: art.state.height, resizing: true),
              options.width != art.state.width || options.height != art.state.height else { return }
        do {
            try document.applyPixelArt(.resizeCanvas(width: options.width, height: options.height,
                                                     offsetX: 0, offsetY: 0),
                                       label: "Cambiar tamaño del lienzo", kind: "canvas.resize",
                                       scope: .document(art.state))
            document.updatePixelEditor {
                $0.centerX = options.width * 500
                $0.centerY = options.height * 500
            }
            stroke.removeAll()
            committedStroke.removeAll()
            renderedImage = nil
        } catch { reportError(error) }
    }

    private func selectTool(_ name: String) {
        isPlaying = false
        stroke.removeAll()
        lastStrokePoint = nil
        lassoPoints.removeAll()
        selectionDraft = nil
        document.updatePixelEditor { $0.tool = name }
    }

    private func pixelPoint(at location: CGPoint, in state: PixelArtState, clamped: Bool = false) -> PixelPoint? {
        let x = Int(floor(location.x / scale)), y = Int(floor(location.y / scale))
        if clamped {
            return PixelPoint(x: min(max(x, 0), state.width - 1), y: min(max(y, 0), state.height - 1))
        }
        guard (0..<state.width).contains(x), (0..<state.height).contains(y) else { return nil }
        return PixelPoint(x: x, y: y)
    }

    private func drawingValue(in art: PixelArtDocument) -> PixelValue {
        if art.editor.tool == "eraser" { return .empty }
        switch art.editor.drawColor {
        case .free(let color): return .normalizedFree(color)
        case .linked(let id): return .linked(id)
        }
    }

    private func handleCanvasDrag(_ gesture: DragGesture.Value) {
        guard let art else { return }
        let tool = art.editor.tool
        if tool == "hand" {
            panOffset = CGSize(width: panStart.width + gesture.translation.width,
                               height: panStart.height + gesture.translation.height)
            return
        }
        guard !readOnly, !art.isReadOnly else { return }
        switch tool {
        case "pencil", "eraser":
            if lastStrokePoint == nil { appendStroke(at: gesture.startLocation, in: art) }
            appendStroke(at: gesture.location, in: art)
        case "line", "rectangle", "ellipse":
            guard let start = pixelPoint(at: gesture.startLocation, in: art.state, clamped: true),
                  let end = pixelPoint(at: gesture.location, in: art.state, clamped: true) else { return }
            let value = drawingValue(in: art)
            stroke = PixelToolGeometry.brush(PixelToolGeometry.outline(from: PixelWrite(x: start.x, y: start.y, value: value),
                                                                       to: PixelWrite(x: end.x, y: end.y, value: value), tool: tool),
                                             size: art.editor.brushSize, width: art.state.width, height: art.state.height)
        case "selection":
            guard let start = pixelPoint(at: gesture.startLocation, in: art.state, clamped: true),
                  let end = pixelPoint(at: gesture.location, in: art.state, clamped: true) else { return }
            selectionDraft = .rectangle(x: min(start.x, end.x), y: min(start.y, end.y),
                                        width: abs(end.x - start.x) + 1, height: abs(end.y - start.y) + 1,
                                        canvasWidth: art.state.width, canvasHeight: art.state.height)
        case "lasso":
            if let point = pixelPoint(at: gesture.location, in: art.state, clamped: true), lassoPoints.last != point {
                lassoPoints.append(point)
                selectionDraft = PixelToolGeometry.lassoSelection(lassoPoints, width: art.state.width,
                                                                  height: art.state.height)
            }
        default: break
        }
    }

    private func endCanvasDrag(_ gesture: DragGesture.Value) {
        guard let art else { return }
        if art.editor.tool == "hand" {
            panStart = panOffset
            return
        }
        guard !readOnly, !art.isReadOnly else { return }
        switch art.editor.tool {
        case "pencil", "eraser", "line", "rectangle", "ellipse":
            handleCanvasDrag(gesture)
            commitStroke()
        case "selection", "lasso":
            handleCanvasDrag(gesture)
            let selected = selectionDraft
            document.updatePixelEditor { $0.selection = selected }
            selectionDraft = nil
            lassoPoints.removeAll()
        case "eyedropper":
            sampleColor(at: gesture.location, in: art)
        case "fill":
            fill(at: gesture.location, in: art)
        case "zoom": zoom(by: 2)
        default: break
        }
    }

    private func appendStroke(at location: CGPoint, in art: PixelArtDocument) {
        guard let point = pixelPoint(at: location, in: art.state) else { return }
        let center = PixelWrite(x: point.x, y: point.y, value: drawingValue(in: art))
        let centers: [PixelWrite]
        if let last = lastStrokePoint {
            guard last.x != center.x || last.y != center.y else { return }
            centers = Array(PixelStroke.line(from: last, to: center).dropFirst())
        } else {
            centers = [center]
        }
        stroke.append(contentsOf: PixelToolGeometry.brush(centers, size: art.editor.brushSize,
                                                          width: art.state.width, height: art.state.height))
        lastStrokePoint = center
    }

    private func commitStroke() {
        defer {
            stroke.removeAll()
            lastStrokePoint = nil
        }
        guard !stroke.isEmpty, let art, let layer = art.editor.activeLayerID,
              let frame = art.editor.activeFrameID else { return }
        let writes = art.editor.selection.map { mask in
            stroke.filter { mask.contains(x: $0.x, y: $0.y) }
        } ?? stroke
        guard !writes.isEmpty else { return }
        let scope = art.editor.selection.map { PixelScope.selection($0, layer: layer, frame: frame) }
            ?? .cel(layer: layer, frame: frame)
        do {
            try document.applyPixelArt(.writePixels(layer: layer, frame: frame, writes: writes),
                                       label: activeTool.label, kind: art.editor.tool, scope: scope)
            committedStroke.append(contentsOf: writes)
        } catch { reportError(error) }
    }

    private func sampleColor(at location: CGPoint, in art: PixelArtDocument) {
        guard let point = pixelPoint(at: location, in: art.state),
              let frame = art.editor.activeFrameID else { return }
        let bitmap = renderedRevision == document.previewRevision
            ? (renderedBitmap ?? PixelArtRenderer.render(art.state, frame: frame))
            : PixelArtRenderer.render(art.state, frame: frame)
        let rgba = bitmap.pixel(x: point.x, y: point.y)
        document.updatePixelEditor { $0.drawColor = .free(rgba) }
    }

    private func fill(at location: CGPoint, in art: PixelArtDocument) {
        guard let point = pixelPoint(at: location, in: art.state),
              let layer = art.editor.activeLayerID, let frame = art.editor.activeFrameID else { return }
        let state = art.state
        let value = drawingValue(in: art)
        let selection = art.editor.selection
        let revision = document.previewRevision
        Task {
            do {
                let writes = try await Task.detached(priority: .userInitiated) {
                    try PixelToolGeometry.floodFill(state, layer: layer, frame: frame,
                                                    at: point, value: value, selection: selection)
                }.value
                guard revision == document.previewRevision, !writes.isEmpty else { return }
                let scope = selection.map { PixelScope.selection($0, layer: layer, frame: frame) }
                    ?? .cel(layer: layer, frame: frame)
                try document.applyPixelArt(.writePixels(layer: layer, frame: frame, writes: writes),
                                           label: "Relleno", kind: "fill", scope: scope)
            } catch is CancellationError {
                return
            } catch { reportError(error) }
        }
    }

    private func onionTint(_ frame: UUID) -> Color {
        guard let art, art.editor.onionSkin, let current = art.editor.activeFrameID,
              let active = art.state.frameIndex(current), let other = art.state.frameIndex(frame) else {
            return Theme.surfaceInk.opacity(0.055)
        }
        let offset = other - active
        if offset < 0 && -offset <= onionPrevious { return Color.purple.opacity(0.25 / Double(-offset)) }
        if offset > 0 && offset <= onionNext { return Color.orange.opacity(0.25 / Double(offset)) }
        return Theme.surfaceInk.opacity(0.055)
    }

    private func selectFrame(at index: Int) {
        guard let art, art.state.frames.indices.contains(index) else { return }
        activateCell(layer: art.editor.activeLayerID ?? art.state.layers[0].id,
                     frame: art.state.frames[index].id)
    }

    private func stepFrame(by delta: Int) {
        guard let art, let id = art.editor.activeFrameID,
              let index = art.state.frameIndex(id) else { return }
        selectFrame(at: min(max(index + delta, 0), art.state.frames.count - 1))
    }

    private func activateCell(layer: UUID, frame: UUID) {
        isPlaying = false
        if art?.editor.activeFrameID != frame {
            renderedImage = nil
            renderedBitmap = nil
            renderedRevision = -1
        }
        document.updatePixelEditor {
            $0.activeLayerID = layer
            $0.activeFrameID = frame
        }
    }

    private func toggleLayer(_ layer: PixelLayer, property: String) {
        guard let art, !readOnly, !art.isReadOnly else { return }
        let change: PixelLayerProperty = property == "visible" ? .visible(!layer.visible) : .locked(!layer.locked)
        do {
            try document.applyPixelArt(.setLayerProperty(layer.id, change),
                                       label: property == "visible" ? "Mostrar u ocultar capa" : "Bloquear o desbloquear capa",
                                       kind: "layer.\(property)", scope: .document(art.state))
        } catch { reportError(error) }
    }

    @ViewBuilder private func layerEditActions(_ layer: PixelLayer, state: PixelArtState) -> some View {
        Button("Renombrar…") { renameLayer(layer) }
        Button("Duplicar capa") { duplicateLayer(layer) }
        Divider()
        Button("Mover arriba") { moveLayer(layer, by: 1) }
            .disabled(state.layerIndex(layer.id) == state.layers.count - 1)
        Button("Mover abajo") { moveLayer(layer, by: -1) }
            .disabled(state.layerIndex(layer.id) == 0)
        Menu("Opacidad") {
            ForEach([25, 50, 75, 100], id: \.self) { percent in
                Button("\(percent) %") { setLayerOpacity(layer, percent: percent) }
            }
        }
        Divider()
        Button("Eliminar capa…", role: .destructive) { deleteLayer(layer) }
            .disabled(state.layers.count == 1 || layer.locked)
    }

    private func renameLayer(_ layer: PixelLayer) {
        guard let art, !readOnly, !art.isReadOnly,
              let name = WorkspacePrompts.nameForNewItem("Renombrar capa", suggested: layer.name,
                                                         action: "Renombrar")?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              name != layer.name else { return }
        do {
            try document.applyPixelArt(.setLayerProperty(layer.id, .name(name)),
                                       label: "Renombrar capa", kind: "layer.name",
                                       scope: .document(art.state))
        } catch { reportError(error) }
    }

    private func duplicateLayer(_ layer: PixelLayer) {
        guard let art, !readOnly, !art.isReadOnly else { return }
        let newID = UUID()
        do {
            try document.applyPixelArt(.duplicateLayer(layer.id, newID: newID, name: "\(layer.name) copia"),
                                       label: "Duplicar capa", kind: "layer.duplicate",
                                       scope: .document(art.state))
            document.updatePixelEditor { $0.activeLayerID = newID }
        } catch { reportError(error) }
    }

    private func moveLayer(_ layer: PixelLayer, by offset: Int) {
        guard let art, !readOnly, !art.isReadOnly,
              let index = art.state.layerIndex(layer.id),
              art.state.layers.indices.contains(index + offset) else { return }
        do {
            try document.applyPixelArt(.moveLayer(layer.id, to: index + offset),
                                       label: "Mover capa", kind: "layer.move",
                                       scope: .document(art.state))
        } catch { reportError(error) }
    }

    private func setLayerOpacity(_ layer: PixelLayer, percent: Int) {
        guard let art, !readOnly, !art.isReadOnly else { return }
        let opacity = (percent * 255 + 50) / 100
        guard layer.opacity != opacity else { return }
        do {
            try document.applyPixelArt(.setLayerProperty(layer.id, .opacity(opacity)),
                                       label: "Cambiar opacidad de capa", kind: "layer.opacity",
                                       scope: .document(art.state))
        } catch { reportError(error) }
    }

    private func deleteLayer(_ layer: PixelLayer) {
        guard let art, !readOnly, !art.isReadOnly,
              art.state.layers.count > 1, !layer.locked,
              WorkspacePrompts.confirmPixelLayerDeletion(layer.name) else { return }
        let nextLayerID = art.state.layers.first { $0.id != layer.id }?.id
        do {
            try document.applyPixelArt(.deleteLayer(layer.id), label: "Eliminar capa",
                                       kind: "layer.delete", scope: .document(art.state))
            if art.editor.activeLayerID == layer.id {
                document.updatePixelEditor { $0.activeLayerID = nextLayerID }
            }
        } catch { reportError(error) }
    }

    private func setFPS(_ fps: Int) {
        guard let art, !readOnly, !art.isReadOnly, let frame = art.editor.activeFrameID else { return }
        do {
            try document.applyPixelArt(.setFrameDuration(frame, milliseconds: 1_000 / fps),
                                       label: "Cambiar velocidad", kind: "frame.duration",
                                       scope: .document(art.state))
        } catch { reportError(error) }
    }

    private func navigateHistory(redo: Bool) {
        do { try document.navigatePixelHistory(redo: redo) }
        catch { reportError(error) }
    }

    private func addLayer() {
        guard let art else { return }
        let layer = PixelLayer(name: "Capa \(art.state.layers.count + 1)")
        do {
            try document.applyPixelArt(.addLayer(layer, at: art.state.layers.count), label: "Agregar capa",
                                       kind: "layer.add", scope: .document(art.state))
            document.updatePixelEditor { $0.activeLayerID = layer.id }
        } catch { reportError(error) }
    }

    private func addFrame() {
        guard let art else { return }
        let frame = PixelFrame(duration: 125)
        do {
            try document.applyPixelArt(.addFrame(frame, at: art.state.frames.count), label: "Agregar fotograma",
                                       kind: "frame.add", scope: .document(art.state))
            document.updatePixelEditor { $0.activeFrameID = frame.id }
        } catch { reportError(error) }
    }

    private func addPaletteColor() {
        guard let art else { return }
        let rgba: PixelRGBA
        switch art.editor.drawColor {
        case .free(let color): rgba = color
        case .linked(let id): rgba = art.state.palette.entry(id)?.color ?? PixelRGBA(0, 0, 0)
        }
        do { try document.addPixelPaletteColor(rgba) }
        catch { reportError(error) }
    }

    private static func image(from bitmap: PixelBitmap) -> NSImage? {
        guard let provider = CGDataProvider(data: Data(bitmap.rgba) as CFData),
              let cgImage = CGImage(width: bitmap.width, height: bitmap.height, bitsPerComponent: 8,
                                    bitsPerPixel: 32, bytesPerRow: bitmap.width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                    provider: provider, decode: nil, shouldInterpolate: false,
                                    intent: .defaultIntent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: bitmap.width, height: bitmap.height))
    }
}

private struct EditorStatusBar: View {
    let document: EditorDocument?
    let settings: AppSettings

    var body: some View {
        HStack(spacing: 18) {
            if let document {
                if document.isSaving { Text("Guardando…") }
                Spacer()
                if let art = document.pixelArt {
                    Text("\(art.state.width) × \(art.state.height) px")
                    Text("\(art.state.layers.count) capas · \(art.state.frames.count) fotogramas")
                    Text("PXA")
                } else if document.previewImage != nil {
                    Text("Vista previa")
                    Text(document.url.pathExtension.uppercased())
                } else {
                    Text("\(document.line):\(document.column)").monospacedDigit()
                    Text(document.language)
                    Text("UTF-8")
                    Button {
                        settings.wrapLines.toggle()
                    } label: {
                        Image(systemName: settings.wrapLines ? "arrow.turn.down.right" : "arrow.right")
                            .foregroundStyle(settings.wrapLines ? .primary : .secondary)
                            .frame(width: Theme.zoom(18), height: Theme.zoom(18))
                    }
                    .buttonStyle(.plain)
                    .help(settings.wrapLines ? "Desactivar ajuste de líneas" : "Activar ajuste de líneas")
                    .accessibilityLabel("Ajustar líneas")
                    .accessibilityValue(settings.wrapLines ? "Activado" : "Desactivado")
                }
            } else { Spacer() }
        }
        .font(Theme.interfaceFont(12)).foregroundStyle(.secondary)
        .padding(.horizontal, 16).frame(height: Theme.zoom(28))
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
    var drag: (() -> NSItemProvider)?
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
                        .font(Theme.interfaceFont(weight: selected ? .medium : .regular))
                        .lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(selected ? .primary : .secondary)
                }
                .padding(.leading, 10).padding(.trailing, 2)
                .frame(maxWidth: 240).frame(height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onDrag { drag?() ?? NSItemProvider() }
            .accessibilityAddTraits(selected ? .isSelected : [])
            Button(action: close) {
                Image(systemName: showsDirtyIndicator ? "circle.fill" : "xmark")
                    .font(.system(size: Theme.zoom(showsDirtyIndicator ? 6 : 9), weight: .medium))
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
                    .font(Theme.codeFont())
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
