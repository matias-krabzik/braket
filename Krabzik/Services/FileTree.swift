import AppKit
import SwiftUI

/// Un nodo del explorador: una carpeta o un archivo.
///
/// `children == nil` significa «todavía no se leyó», no «está vacía»: la carga es
/// perezosa y esa distinción es la que decide si hay que leer el disco. `watcher`
/// mantiene la carpeta al día y se cancela en `deinit`. Confinado al main actor.
@MainActor final class FileNode: NSObject {
    let url: URL
    let name: String
    let isDirectory: Bool
    let project: CodeProject?
    var children: [FileNode]?
    var loading = false
    var expanded: Bool
    var projectIcon: NSImage?
    var flutterProject = false
    var loadingIcon = false
    var watcher: DispatchSourceFileSystemObject?

    init(url: URL, isDirectory: Bool, project: CodeProject? = nil) {
        self.url = url
        self.name = project?.name ?? url.lastPathComponent
        self.isDirectory = isDirectory
        self.project = project
        self.expanded = project != nil
    }

    deinit { watcher?.cancel() }
}

/// El explorador de archivos: un `NSOutlineView` nativo dentro de SwiftUI.
///
/// Es AppKit y no una `List` de SwiftUI porque la carga perezosa, el menú contextual y
/// miles de filas se resuelven ahí sin pelear con el framework.
struct FileTree: NSViewRepresentable {
    let workspace: Workspace
    let workspaceURL: URL
    let revision: Int
    let controller: WorkspaceController

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let outline = FileTreeOutlineView()
        let column = NSTableColumn(identifier: .init("files"))
        column.minWidth = 180
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.allowsMultipleSelection = true
        outline.rowHeight = SidebarTreeStyle.rowHeight
        outline.indentationPerLevel = SidebarTreeStyle.indent
        outline.intercellSpacing = NSSize(width: 0, height: 0)
        outline.style = .sourceList
        outline.backgroundColor = .clear
        outline.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        outline.delegate = context.coordinator
        outline.dataSource = context.coordinator
        outline.target = context.coordinator
        outline.action = #selector(Coordinator.clicked)
        outline.handleKey = { [weak coordinator = context.coordinator] event in coordinator?.handleKey(event) ?? false }
        outline.registerForDraggedTypes([.fileURL])
        outline.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        outline.setDraggingSourceOperationMask(.copy, forLocal: false)
        outline.autosaveExpandedItems = false
        let menu = NSMenu()
        menu.delegate = context.coordinator
        outline.menu = menu
        scroll.documentView = outline
        context.coordinator.outline = outline
        return scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.update(workspace, at: workspaceURL, revision: revision)
        if let request = controller.newFileRequest {
            context.coordinator.requestNewFile(request, in: controller.newFileDirectory)
        }
    }

    /// Dueño del árbol: qué nodos hay, cuándo se leen y qué se observa.
    ///
    /// `generation` cambia al cambiar de proyecto y con eso se descartan las lecturas en
    /// vuelo del anterior. Las carpetas generadas (`node_modules`, `.git`, …) no se listan,
    /// y un symlink a directorio se muestra como hoja: seguirlo podría dar vueltas o salir
    /// del proyecto. Confinado al main actor; las lecturas de disco van a una cola propia.
    @MainActor final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate,
        NSMenuDelegate, NSTextFieldDelegate {
        weak var outline: NSOutlineView?
        let controller: WorkspaceController
        var roots: [FileNode] = []
        var lastRevision = -1
        var lastURL: URL?
        var generation = UUID()
        private var editingNode: FileNode?
        private var deferredReloads: Set<URL> = []
        private var hoveredDropURL: URL?
        private var pendingSelectionURL: URL?
        private var pendingRenameURL: URL?
        private var lastCreationRequest: UUID?
        private let queue = DispatchQueue(label: "com.krabzik.files", qos: .userInitiated)
        nonisolated private static let excluded: Set<String> = [
            ".git",
            "node_modules",
            "vendor",
            ".build",
            "DerivedData",
            "dist",
            ".next",
            ".angular",
            ".DS_Store"
        ]

        init(controller: WorkspaceController) { self.controller = controller }

        func update(_ workspace: Workspace, at url: URL, revision: Int) {
            guard editingNode == nil else { return }
            guard revision != lastRevision || url != lastURL else { return }
            let sameWorkspace = lastURL == url
            lastRevision = revision
            lastURL = url
            if !sameWorkspace { generation = UUID() }
            let previous = sameWorkspace ? Dictionary(uniqueKeysWithValues: roots.map { ($0.url, $0) }) : [:]
            // En solo lectura las carpetas externas no se montan (S1).
            roots = controller.mountedProjects.map { project in
                let directory = project.directory(relativeTo: url)
                if let node = previous[directory], node.project == project { return node }
                return FileNode(url: directory, isDirectory: true, project: project)
            }
            roots += controller.files.standaloneScripts.map { file in
                previous[file] ?? FileNode(url: file, isDirectory: false)
            }
            outline?.reloadData()
            for root in roots where root.isDirectory {
                if root.children == nil { load(root) }
                else { restoreExpansion(root) }
            }
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            if let node = item as? FileNode { return node.children?.count ?? 0 }
            return roots.count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            (item as? FileNode)?.children?[index] ?? roots[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            (item as? FileNode)?.isDirectory ?? false
        }

        func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
            if let node = item as? FileNode {
                node.expanded = true
                if node.children == nil { load(node) }
            }
            return true
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? FileNode else { return nil }
            return FileTreeCell(node: node, depth: outlineView.level(forItem: node), expanded: outlineView.isItemExpanded(node),
                                monochrome: controller.workspace?.codeIconMonochrome == true) {
                [weak self, weak node, weak outlineView] in
                guard let self, let node, let outlineView else { return }
                if outlineView.isItemExpanded(node) { outlineView.collapseItem(node) }
                else { outlineView.expandItem(node) }
                self.refreshDisclosure()
            }
        }

        func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
            let row = FileTreeRow()
            row.outline = outlineView
            row.node = item as? FileNode
            return row
        }

        func outlineViewItemDidExpand(_ notification: Notification) { refreshDisclosure() }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            if let node = notification.userInfo?["NSObject"] as? FileNode { node.expanded = false }
            refreshDisclosure()
        }

        private func refreshDisclosure() {
            guard let outline else { return }
            let visible = outline.rows(in: outline.visibleRect)
            guard visible.location != NSNotFound else { return }
            for index in visible.location..<NSMaxRange(visible) {
                if let cell = outline.view(atColumn: 0, row: index, makeIfNecessary: false) as? FileTreeCell,
                   let node = outline.item(atRow: index) as? FileNode {
                    cell.updateDisclosure(outline.isItemExpanded(node))
                }
                outline.rowView(atRow: index, makeIfNecessary: false)?.needsDisplay = true
            }
        }

        private func restoreExpansion(_ node: FileNode) {
            if node.expanded {
                outline?.expandItem(node)
                for child in node.children ?? [] where child.isDirectory { restoreExpansion(child) }
            }
        }

        private func loadProjectIcon(_ node: FileNode) {
            guard let project = node.project, !node.loadingIcon else { return }
            node.loadingIcon = true
            let token = generation
            let directory = node.url
            Task { [weak self, weak node] in
                let files = await Task.detached(priority: .utility) {
                    ProjectIconFiles.read(at: directory, kind: project.kind)
                }.value
                guard let self, let node else { return }
                node.loadingIcon = false
                guard self.generation == token else { return }
                node.projectIcon = files.favicons.lazy.compactMap { FileIcons.favicon($0) }.first
                    ?? files.technology.flatMap { FileIcons.asset($0) } ?? FileIcons.project(project)
                if self.editingNode == nil { self.outline?.reloadItem(node) }
                else { self.deferredReloads.insert(node.url) }
            }
        }

        @objc func clicked() {
            guard let outline, outline.clickedRow >= 0, let node = outline.item(atRow: outline.clickedRow) as? FileNode else { return }
            guard outline.selectedRowIndexes.count <= 1 else { return }
            if !node.isDirectory {
                if node.url.lastPathComponent.hasSuffix(".flow.json") { controller.openWorkflowFile(node.url) }
                else { controller.files.open(node.url) }
            }
        }

        private func load(_ node: FileNode) {
            guard !node.loading else { return }
            node.loading = true
            loadProjectIcon(node)
            let token = generation
            let url = node.url
            let inheritedFlutterProject = node.flutterProject
            queue.async { [weak self, weak node] in
                let result: Result<[(URL, Bool)], Error> = Result {
                    let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
                    return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(keys))
                        .filter { !Self.excluded.contains($0.lastPathComponent) }
                        .map { child in
                            let values = try child.resourceValues(forKeys: keys)
                            // A directory symlink is not followed recursively.
                            return (child, values.isDirectory == true && values.isSymbolicLink != true)
                        }.sorted {
                            if $0.1 != $1.1 { return $0.1 }
                            return $0.0.lastPathComponent.localizedStandardCompare($1.0.lastPathComponent) == .orderedAscending
                        }
                }
                DispatchQueue.main.async {
                    guard let self, let node else { return }
                    node.loading = false
                    guard self.generation == token else { return }
                    guard self.editingNode == nil else { self.deferredReloads.insert(url)
                        return }
                    switch result {
                    case .success(let entries):
                        let old = Dictionary(uniqueKeysWithValues: (node.children ?? []).map { ($0.url, $0) })
                        node.flutterProject = inheritedFlutterProject || entries.contains { $0.0.lastPathComponent == "pubspec.yaml" }
                        node.children = entries.map { entry in
                            let child = old[entry.0] ?? FileNode(url: entry.0, isDirectory: entry.1)
                            child.flutterProject = node.flutterProject
                            return child
                        }
                        self.outline?.reloadItem(node, reloadChildren: true)
                        self.restoreExpansion(node)
                        if let selected = self.pendingSelectionURL,
                           let child = node.children?
                           .first(where: {
                           $0.url.resolvingSymlinksInPath().standardizedFileURL == selected.resolvingSymlinksInPath().standardizedFileURL
                           }),
                           let row = self.outline?.row(forItem: child), row >= 0 {
                            self.outline?.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                            self.pendingSelectionURL = nil
                            self.outline?.scrollRowToVisible(row)
                            if self.pendingRenameURL == selected {
                                self.pendingRenameURL = nil
                                self.beginRename(child, selectStem: true)
                            }
                        }
                        self.refreshDisclosure()
                        self.watch(node)
                    case .failure(let error):
                        node.children = []
                        self.outline?.reloadItem(node)
                        self.controller.errors.report(error)
                    }
                }
            }
        }

        private func watch(_ node: FileNode) {
            guard node.watcher == nil else { return }
            let fd = open(node.url.path, O_EVTONLY)
            guard fd >= 0 else {
                // Sin observador la carpeta deja de actualizarse sola. La app sigue
                // funcionando, pero el usuario va a ver un árbol viejo sin saber por qué.
                Log.workspace.notice("sin observador (errno \(errno, privacy: .public)) en \(node.url.path, privacy: .private)")
                return
            }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
            source.setEventHandler { [weak self, weak node] in
                guard let self, let node else { return }
                self.load(node)
            }
            source.setCancelHandler { Darwin.close(fd) }
            node.watcher = source
            source.resume()
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let outline, outline.clickedRow >= 0, let node = outline.item(atRow: outline.clickedRow) as? FileNode else { return }
            let selection = selectedNodes(clicked: node)
            if selection.count == 1, node.isDirectory, (try? fileSystem.checkedFolder(node.url)) != nil {
                add("Nuevo archivo…", to: menu, action: #selector(newFile(_:)), represented: node)
                add("Nueva carpeta…", to: menu, action: #selector(newFolder(_:)), represented: node)
                add("Pegar", to: menu, action: #selector(pasteHere(_:)), represented: node)
                menu.addItem(.separator())
            }
            if let project = node.project, selection.count == 1 {
                add("Comando…", to: menu, action: #selector(editCommand(_:)), represented: project)
                add("Mostrar en Finder", to: menu, action: #selector(reveal(_:)), represented: node)
                menu.addItem(.separator())
                add("Quitar del proyecto", to: menu, action: #selector(removeRoot(_:)), represented: project)
            } else if selection.count == 1, !node.isDirectory, roots.contains(where: { $0 === node }) {
                add("Renombrar…", to: menu, action: #selector(renameAction(_:)), represented: node)
                add("Mostrar en Finder", to: menu, action: #selector(reveal(_:)), represented: node)
                add("Quitar del proyecto", to: menu, action: #selector(removeScript(_:)), represented: node)
            } else if selection.allSatisfy({ canChange($0) }) {
                if selection.count == 1 {
                    add("Renombrar", to: menu, action: #selector(renameAction(_:)), represented: node)
                    add("Duplicar", to: menu, action: #selector(duplicate(_:)), represented: node)
                }
                add("Copiar", to: menu, action: #selector(copySelected(_:)), represented: node)
                add("Copiar ruta relativa", to: menu, action: #selector(copyPath(_:)), represented: node)
                add("Mostrar en Finder", to: menu, action: #selector(reveal(_:)), represented: node)
                menu.addItem(.separator())
                add("Mover a la Papelera", to: menu, action: #selector(trashSelected(_:)), represented: node)
            } else {
                add("Copiar ruta relativa", to: menu, action: #selector(copyPath(_:)), represented: node)
                add("Mostrar en Finder", to: menu, action: #selector(reveal(_:)), represented: node)
            }
            for item in menu.items where item.action != #selector(reveal(_:)) && item.action != #selector(copyPath(_:)) {
                item.isEnabled = !controller.isReadOnly && controller.fileOperation == nil
            }
        }

        @objc func newFile(_ item: NSMenuItem) {
            if let node = item.representedObject as? FileNode { create(in: node, directory: false) }
        }
        @objc func newFolder(_ item: NSMenuItem) {
            if let node = item.representedObject as? FileNode { create(in: node, directory: true) }
        }
        @objc func editCommand(_ item: NSMenuItem) { controller.commandProject = item.representedObject as? CodeProject }
        @objc func removeScript(_ item: NSMenuItem) {
            if let node = item.representedObject as? FileNode { controller.files.removeScript(node.url) }
        }

        @objc func removeRoot(_ item: NSMenuItem) {
            if let project = item.representedObject as? CodeProject { controller.projects.remove(project.id) } }

        private var fileSystem: ExplorerFileSystem {
            ExplorerFileSystem(roots: roots.map { $0.isDirectory ? $0.url : $0.url.deletingLastPathComponent() })
        }

        private func canChange(_ node: FileNode) -> Bool {
            controller.fileOperation == nil && node.project == nil && (try? fileSystem.checkedSource(node.url)) != nil
        }

        private func add(_ title: String, to menu: NSMenu, action: Selector, represented: Any) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = represented
            menu.addItem(item)
        }

        private func selectedNodes(clicked node: FileNode? = nil) -> [FileNode] {
            guard let outline else { return node.map { [$0] } ?? [] }
            if let node, !outline.selectedRowIndexes.contains(outline.row(forItem: node)) { return [node] }
            let selected = outline.selectedRowIndexes.compactMap { outline.item(atRow: $0) as? FileNode }
            return selected.isEmpty ? node.map { [$0] } ?? [] : selected.filter { candidate in
                !selected.contains { other in other !== candidate && ExplorerFileSystem.contains(candidate.url, in: other.url) }
            }
        }

        private func report(_ error: Error) { controller.errors.report(error) }

        private func refresh(_ directories: [URL]) {
            for directory in Set(directories.map(\.standardizedFileURL)) {
                if let node = findNode(at: directory) {
                    outline?.expandItem(node)
                    load(node)
                }
            }
            controller.session.touch()
        }

        private func findNode(at url: URL) -> FileNode? {
            func find(_ node: FileNode) -> FileNode? {
                if node.url.resolvingSymlinksInPath().standardizedFileURL.path == url.resolvingSymlinksInPath()
                    .standardizedFileURL.path { return node }
                for child in node.children ?? [] where child.isDirectory {
                    if let result = find(child) { return result }
                }
                return nil
            }
            return roots.lazy.compactMap(find).first
        }

        func requestNewFile(_ request: UUID, in directory: URL?) {
            guard lastCreationRequest != request else { return }
            lastCreationRequest = request
            Task { [weak self] in
                guard let self, self.controller.newFileRequest == request else { return }
                self.controller.newFileRequest = nil
                self.createFileInline(in: directory)
            }
        }

        private func createFileInline(in directory: URL?) {
            guard !controller.isReadOnly, controller.fileOperation == nil, let workspaceURL = controller.workspaceURL else { return }
            let selected = selectedNodes().first
            let folder = directory ?? selected.map { $0.isDirectory ? $0.url : $0.url.deletingLastPathComponent() }
                ?? roots.first(where: \.isDirectory)?.url ?? workspaceURL.deletingLastPathComponent()
            do {
                let fs = ExplorerFileSystem(roots: [folder])
                let name = FileManager.default.fileExists(atPath: folder.appendingPathComponent("nuevo.txt").path)
                    ? try fs.availableName(for: "nuevo.txt", in: folder) : "nuevo.txt"
                let url = try fs.create(name: name, in: folder, directory: false)
                if !roots.contains(where: { $0.isDirectory && ExplorerFileSystem.contains(folder, in: $0.url) }),
                   var workspace = controller.workspace {
                    let base = workspaceURL.deletingLastPathComponent()
                    let path = folder.standardizedFileURL == base.standardizedFileURL ? "." : folder.path
                    workspace.projects.append(CodeProject(name: folder.lastPathComponent, path: path, kind: .files, command: ""))
                    controller.session.write(workspace)
                    update(workspace, at: workspaceURL, revision: controller.session.revision)
                }
                Task {
                    do {
                        try await controller.docs.open(url) { self.controller.workspaceURL == workspaceURL }
                        guard controller.workspaceURL == workspaceURL else { return }
                        controller.docs.selected?.focusEditorOnOpen = false
                        showCreatedFile(url, in: folder)
                    } catch { report(error) }
                }
            } catch { report(error) }
        }

        private func showCreatedFile(_ url: URL, in folder: URL) {
            guard let parent = findNode(at: folder), let outline else { return }
            let child = parent.children?.first { $0.url.resolvingSymlinksInPath() == url.resolvingSymlinksInPath() }
                ?? FileNode(url: url, isDirectory: false)
            var children = parent.children ?? []
            if !children.contains(where: { $0 === child }) { children.append(child) }
            parent.children = children.sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            parent.expanded = true
            outline.reloadItem(parent, reloadChildren: true)
            outline.expandItem(parent)
            let row = outline.row(forItem: child)
            guard row >= 0 else { return }
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            outline.scrollRowToVisible(row)
            deferredReloads.insert(folder)
            // SwiftUI termina de insertar la pestaña antes de entregar el foco al
            // editor de nombres de AppKit; hacerlo durante ese layout lo cancela.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self, self.controller.selectedDocument?.url.standardizedFileURL == url.standardizedFileURL,
                      let current = self.findNode(at: folder)?.children?.first(where: {
                          $0.url.standardizedFileURL.path == url.standardizedFileURL.path
                      }) else { return }
                let row = self.outline?.row(forItem: current) ?? -1
                guard row >= 0 else { return }
                self.outline?.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                self.beginRename(current, selectStem: true)
            }
        }

        private func create(in node: FileNode, directory: Bool) {
            if !directory { createFileInline(in: node.url)
                return }
            guard controller.fileOperation == nil, !controller.isReadOnly else { return }
            let title = directory ? "Nueva carpeta" : "Nuevo archivo"
            guard let name = WorkspacePrompts.nameForNewItem(title, suggested: directory ? "Nueva carpeta" : "nuevo.txt") else { return }
            do {
                let url = try fileSystem.create(name: name, in: node.url, directory: directory)
                pendingSelectionURL = url
                refresh([node.url])
                if !directory { controller.files.open(url) }
            } catch { report(error) }
        }

        @objc private func renameAction(_ item: NSMenuItem) {
            guard let node = item.representedObject as? FileNode else { return }
            if node.isDirectory { beginRename(node) }
            else { controller.renameFile(node.url) }
        }

        private func beginRename(_ node: FileNode, selectStem: Bool = false) {
            guard !controller.isReadOnly, canChange(node) else { return }
            guard let outline, outline.row(forItem: node) >= 0,
                  let cell = outline.view(atColumn: 0, row: outline.row(forItem: node), makeIfNecessary: true)
                    as? FileTreeCell,
                  let field = cell.textField else { return }
            editingNode = node
            field.isEditable = true
            field.isSelectable = true
            field.delegate = self
            field.selectText(nil)
            if selectStem, let editor = field.currentEditor() as? NSTextView {
                editor.setSelectedRange(NSRange(location: 0, length: node.url.deletingPathExtension().lastPathComponent.utf16.count))
            }
        }

        private func flushDeferredReloads() {
            let folders = Array(deferredReloads)
            deferredReloads.removeAll()
            DispatchQueue.main.async { [weak self] in self?.refresh(folders) }
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let node = editingNode, let field = notification.object as? NSTextField else { return }
            editingNode = nil
            defer { flushDeferredReloads() }
            field.isEditable = false
            field.delegate = nil
            let name = field.stringValue
            field.stringValue = node.name
            guard name != node.name else { return }
            transfer([node.url], to: node.url.deletingLastPathComponent(), moving: true,
                     external: false, renamed: name)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
            if let node = editingNode { control.stringValue = node.name }
            editingNode = nil
            (control as? NSTextField)?.isEditable = false
            flushDeferredReloads()
            control.window?.makeFirstResponder(outline)
            return true
        }

        @objc private func duplicate(_ item: NSMenuItem) {
            guard !controller.isReadOnly, let node = item.representedObject as? FileNode, canChange(node) else { return }
            do {
                let folder = node.url.deletingLastPathComponent()
                let name = try fileSystem.availableName(for: node.name, in: folder)
                transfer([node.url], to: folder, moving: false, external: false, renamed: name)
            } catch { report(error) }
        }

        @objc private func copySelected(_ item: NSMenuItem) {
            guard let node = item.representedObject as? FileNode else { return }
            copy(selectedNodes(clicked: node))
        }

        private func copy(_ nodes: [FileNode]) {
            guard !nodes.isEmpty, nodes.allSatisfy(canChange) else { return }
            let board = NSPasteboard.general
            board.clearContents()
            _ = board.writeObjects(nodes.map { $0.url as NSURL })
        }

        @objc private func copyPath(_ item: NSMenuItem) {
            guard let node = item.representedObject as? FileNode else { return }
            let paths = selectedNodes(clicked: node).map { selected -> String in
                let root = roots.first { ExplorerFileSystem.contains(selected.url, in: $0.url) }?.url
                guard let root, selected.url != root else { return "." }
                return String(selected.url.path.dropFirst(root.path.count + 1))
            }
            let board = NSPasteboard.general
            board.clearContents()
            board.setString(paths.joined(separator: "\n"), forType: .string)
        }

        @objc private func reveal(_ item: NSMenuItem) {
            guard let node = item.representedObject as? FileNode else { return }
            NSWorkspace.shared.activateFileViewerSelecting(selectedNodes(clicked: node).map(\.url))
        }

        @objc private func pasteHere(_ item: NSMenuItem) {
            guard let node = item.representedObject as? FileNode else { return }
            paste(to: node.url, moving: false)
        }

        private func paste(to folder: URL, moving: Bool) {
            guard !controller.isReadOnly else { return }
            let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self],
                                                        options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            guard !urls.isEmpty else { return }
            let internalMove = moving && urls.allSatisfy { url in roots.contains { ExplorerFileSystem.contains(url, in: $0.url) } }
            transfer(urls, to: folder, moving: internalMove, external: !internalMove)
        }

        @objc private func trashSelected(_ item: NSMenuItem) {
            guard let node = item.representedObject as? FileNode else { return }
            trash(selectedNodes(clicked: node))
        }

        private func disk<T: Sendable>(_ operation: @escaping @Sendable (ExplorerFileSystem) throws -> T) async throws -> T {
            let roots = fileSystem.roots
            return try await Task.detached(priority: .userInitiated) {
                try operation(ExplorerFileSystem(roots: roots))
            }.value
        }

        private func trash(_ nodes: [FileNode]) {
            guard !controller.isReadOnly, controller.fileOperation == nil,
                  !nodes.isEmpty, nodes.allSatisfy(canChange) else { return }
            let urls = nodes.map(\.url)
            let affected = urls.flatMap { controller.docs.affected(by: $0) }
            let running = activeProjects(affectedBy: urls)
            controller.fileOperation = FileOperationStatus(action: "Moviendo a la Papelera", total: urls.count)
            Task {
                defer { controller.fileOperation = nil }
                guard await prepareDocuments(at: urls, saving: true) else { return }
                if !running.isEmpty, !WorkspacePrompts.confirmStopAffectedProcesses(running.map(\.name)) { return }
                guard await stop(running) else { return }
                var moved: [(URL, URL)] = []
                for url in urls {
                    controller.fileOperation?.filename = url.lastPathComponent
                    do { moved.append((url, try await disk { try $0.trash(url) })) }
                    catch { report(error) }
                    controller.fileOperation?.completed += 1
                }
                for document in affected where moved.contains(where: { ExplorerFileSystem.contains(document.url, in: $0.0) }) {
                    controller.docs.close(document)
                }
                for (original, _) in moved { controller.files.removeScript(original) }
                refresh(moved.map { $0.0.deletingLastPathComponent() })
                if !moved.isEmpty { registerUndoTrash(moved) }
            }
        }

        private func activeProjects(affectedBy urls: [URL]) -> [CodeProject] {
            guard let workspaceURL = controller.workspaceURL else { return [] }
            return controller.runnableProjects.filter { project in
                guard controller.runner.runs[project.id]?.status.active == true else { return false }
                let root = project.directory(relativeTo: workspaceURL)
                return urls.contains { ExplorerFileSystem.contains($0, in: root) || ExplorerFileSystem.contains(root, in: $0) }
            }
        }

        private func prepareDocuments(at urls: [URL], saving: Bool) async -> Bool {
            let affected = urls.flatMap { controller.docs.affected(by: $0) }
            for document in affected {
                if document.sqlExecution.isRunning {
                    guard controller.session.dialogs.confirmCancelQuery() else { return false }
                    controller.database.cancel(document.sqlExecution)
                }
                if saving, !(await controller.files.confirmSave(document)) { return false }
            }
            return true
        }

        private func stop(_ projects: [CodeProject]) async -> Bool {
            guard !projects.isEmpty else { return true }
            for project in projects { controller.runner.stop(project.id) }
            let deadline = Date().addingTimeInterval(5)
            while projects.contains(where: { controller.runner.runs[$0.id]?.status.active == true }), Date() < deadline {
                try? await Task.sleep(for: .milliseconds(80))
            }
            if projects.contains(where: { controller.runner.runs[$0.id]?.status.active == true }) {
                report(ExplorerFileError.processStillRunning)
                return false
            }
            return true
        }

        private func transfer(_ urls: [URL], to folder: URL, moving: Bool, external: Bool, renamed: String? = nil) {
            guard !controller.isReadOnly, controller.fileOperation == nil, !urls.isEmpty else { return }
            controller.fileOperation = FileOperationStatus(action: moving ? "Moviendo" : "Copiando", total: urls.count)
            Task {
                defer { controller.fileOperation = nil }
                let running = moving ? activeProjects(affectedBy: urls) : []
                if !running.isEmpty {
                    guard WorkspacePrompts.confirmStopAffectedProcesses(running.map(\.name)), await stop(running) else { return }
                }
                if moving, !(await prepareDocuments(at: urls, saving: false)) { return }
                let fs = fileSystem
                var refreshFolders = [folder]
                var changes: [(URL?, URL, URL?)] = []
                defer {
                    refresh(refreshFolders)
                    if !changes.isEmpty { registerUndoTransfer(changes) }
                }
                for url in urls {
                    controller.fileOperation?.filename = url.lastPathComponent
                    defer { controller.fileOperation?.completed += 1 }
                    do {
                        var name = renamed ?? url.lastPathComponent
                        var originalDestination = try fs.destination(name: name, in: folder)
                        if originalDestination == url.standardizedFileURL {
                            if moving { continue }
                            name = try fs.availableName(for: name, in: folder)
                            originalDestination = try fs.destination(name: name, in: folder)
                        }
                        var replaced: URL?
                        if FileManager.default.fileExists(atPath: originalDestination.path) {
                            switch WorkspacePrompts.resolveConflict(name) {
                            case .keepBoth: name = try fs.availableName(for: name, in: folder)
                            case .skip: continue
                            case .cancel: return
                            case .replace:
                                guard await prepareDocuments(at: [originalDestination], saving: true) else { return }
                                let destinationProcesses = activeProjects(affectedBy: [originalDestination])
                                if !destinationProcesses.isEmpty {
                                    guard WorkspacePrompts.confirmStopAffectedProcesses(destinationProcesses.map(\.name)),
                                          await stop(destinationProcesses) else { return }
                                }
                                let open = controller.docs.affected(by: originalDestination)
                                let target = originalDestination
                                replaced = try await disk { try $0.trash(target) }
                                for document in open { controller.docs.close(document) }
                            }
                        }
                        let result: URL
                        do {
                            let sourceIsInternal = roots.contains { ExplorerFileSystem.contains(url, in: $0.url) }
                            let targetName = name
                            result = try await disk { system in
                                moving ? try system.move(url, to: folder, name: targetName)
                                    : try system.copy(url, to: folder, name: targetName, external: external && !sourceIsInternal)
                            }
                        } catch {
                            if let replaced, !FileManager.default.fileExists(atPath: originalDestination.path) {
                                let target = originalDestination
                                try? await disk { _ in try FileManager.default.moveItem(at: replaced, to: target) }
                            }
                            throw error
                        }
                        if moving {
                            controller.docs.relocate(from: url, to: result)
                            controller.connections.relocateScript(from: url, to: result)
                            controller.files.relocateScripts(from: url, to: result)
                            refreshFolders.append(url.deletingLastPathComponent())
                        }
                        changes.append((moving ? url : nil, result, replaced))
                        pendingSelectionURL = result
                    } catch { report(error) }
                }
            }
        }

        private func registerUndoTransfer(_ changes: [(URL?, URL, URL?)]) {
            outline?.undoManager?.registerUndo(withTarget: self) { coordinator in
                guard coordinator.controller.fileOperation == nil else { return }
                coordinator.controller.fileOperation = FileOperationStatus(action: "Deshaciendo", total: changes.count)
                Task {
                defer { coordinator.controller.fileOperation = nil }
                var folders: [URL] = []
                for (source, destination, replaced) in changes.reversed() {
                    coordinator.controller.fileOperation?.filename = destination.lastPathComponent
                    defer { coordinator.controller.fileOperation?.completed += 1 }
                    do {
                        guard FileManager.default.fileExists(atPath: destination.path) else {
                            throw ExplorerFileError.missingSource
                        }
                        if let source {
                            guard !FileManager.default.fileExists(atPath: source.path) else {
                                throw ExplorerFileError.alreadyExists
                            }
                            try await coordinator.disk { _ in try FileManager.default.moveItem(at: destination, to: source) }
                            coordinator.controller.docs.relocate(from: destination, to: source)
                            coordinator.controller.connections.relocateScript(from: destination, to: source)
                            coordinator.controller.files.relocateScripts(from: destination, to: source)
                            folders.append(source.deletingLastPathComponent())
                        } else {
                            let open = coordinator.controller.docs.affected(by: destination)
                            guard !open.contains(where: { $0.isDirty || $0.sqlExecution.isRunning }) else {
                                throw ExplorerFileError.unsavedChanges
                            }
                            _ = try await coordinator.disk { try $0.trash(destination) }
                            for document in open { coordinator.controller.docs.close(document) }
                        }
                        if let replaced {
                            try await coordinator.disk { _ in try FileManager.default.moveItem(at: replaced, to: destination) }
                        }
                        folders.append(destination.deletingLastPathComponent())
                    } catch { coordinator.report(error) }
                }
                coordinator.refresh(folders)
                }
            }
            outline?.undoManager?.setActionName("Mover archivos")
        }

        private func registerUndoTrash(_ moved: [(URL, URL)]) {
            outline?.undoManager?.registerUndo(withTarget: self) { coordinator in
                guard coordinator.controller.fileOperation == nil else { return }
                coordinator.controller.fileOperation = FileOperationStatus(action: "Restaurando", total: moved.count)
                Task {
                defer { coordinator.controller.fileOperation = nil }
                for (original, trash) in moved {
                    coordinator.controller.fileOperation?.filename = original.lastPathComponent
                    defer { coordinator.controller.fileOperation?.completed += 1 }
                    do {
                        guard !FileManager.default.fileExists(atPath: original.path) else {
                            throw ExplorerFileError.alreadyExists
                        }
                        try await coordinator.disk { _ in try FileManager.default.moveItem(at: trash, to: original) }
                        coordinator.controller.files.remember(original)
                    } catch { coordinator.report(error) }
                }
                coordinator.refresh(moved.map { $0.0.deletingLastPathComponent() })
                }
            }
            outline?.undoManager?.setActionName("Mover a la Papelera")
        }

        func handleKey(_ event: NSEvent) -> Bool {
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let command = modifiers.contains(.command)
            let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
            if command && key == "c" {
                copy(selectedNodes())
                return true
            }
            if command && key == "v" {
                let node = selectedNodes().first
                let folder = node.map { $0.isDirectory ? $0.url : $0.url.deletingLastPathComponent() } ?? roots.first?.url
                if let folder { paste(to: folder, moving: modifiers.contains(.option)) }
                return true
            }
            if command && key == "d", let node = selectedNodes().first, node.project == nil {
                let item = NSMenuItem()
                item.representedObject = node
                duplicate(item)
                return true
            }
            if command && event.keyCode == 51 {
                trash(selectedNodes())
                return true
            }
            if !command && event.keyCode == 36, let node = selectedNodes().first, node.project == nil {
                beginRename(node)
                return true
            }
            return false
        }

        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
            guard let node = item as? FileNode, canChange(node), !controller.isReadOnly else { return nil }
            return node.url as NSURL
        }

        func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo,
                         proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
            guard !controller.isReadOnly, controller.fileOperation == nil, let node = dropFolder(for: item),
                  let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                                 options: [.urlReadingFileURLsOnly: true]) as? [URL],
                  !urls.isEmpty, !urls.contains(where: { ExplorerFileSystem.contains(node.url, in: $0) }),
                  (try? fileSystem.checkedFolder(node.url)) != nil else { return [] }
            outlineView.setDropItem(node, dropChildIndex: NSOutlineViewDropOnItemIndex)
            if hoveredDropURL != node.url {
                hoveredDropURL = node.url
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { [weak self, weak node, weak outlineView] in
                    guard let self, let node, let outlineView, self.hoveredDropURL == node.url,
                          !outlineView.isItemExpanded(node) else { return }
                    outlineView.expandItem(node)
                }
            }
            return info.draggingSource as? NSOutlineView === outlineView && !NSEvent.modifierFlags.contains(.option)
                ? .move : .copy
        }

        func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo,
                         item: Any?, childIndex index: Int) -> Bool {
            hoveredDropURL = nil
            guard !controller.isReadOnly, controller.fileOperation == nil, let node = dropFolder(for: item),
                  let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                                 options: [.urlReadingFileURLsOnly: true]) as? [URL],
                  !urls.isEmpty else { return false }
            let moving = info.draggingSource as? NSOutlineView === outlineView && !NSEvent.modifierFlags.contains(.option)
            transfer(urls, to: node.url, moving: moving, external: !moving)
            return true
        }

        private func dropFolder(for item: Any?) -> FileNode? {
            if let node = item as? FileNode {
                return node.isDirectory ? node : findNode(at: node.url.deletingLastPathComponent())
            }
            if roots.count == 1 { return roots.first }
            let selected = selectedNodes()
            guard selected.count == 1 else { return nil }
            let node = selected[0]
            return node.isDirectory ? node : findNode(at: node.url.deletingLastPathComponent())
        }
    }
}
