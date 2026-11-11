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
        outline.rowHeight = 29
        outline.indentationPerLevel = 18
        outline.intercellSpacing = NSSize(width: 0, height: 0)
        outline.style = .sourceList
        outline.backgroundColor = .clear
        outline.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        outline.delegate = context.coordinator
        outline.dataSource = context.coordinator
        outline.target = context.coordinator
        outline.action = #selector(Coordinator.clicked)
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
    }

    /// Dueño del árbol: qué nodos hay, cuándo se leen y qué se observa.
    ///
    /// `generation` cambia al cambiar de proyecto y con eso se descartan las lecturas en
    /// vuelo del anterior. Las carpetas generadas (`node_modules`, `.git`, …) no se listan,
    /// y un symlink a directorio se muestra como hoja: seguirlo podría dar vueltas o salir
    /// del proyecto. Confinado al main actor; las lecturas de disco van a una cola propia.
    @MainActor final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
        weak var outline: NSOutlineView?
        let controller: WorkspaceController
        var roots: [FileNode] = []
        var lastRevision = -1
        var lastURL: URL?
        var generation = UUID()
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
            outline?.reloadData()
            for root in roots {
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
                self.outline?.reloadItem(node)
            }
        }

        @objc func clicked() {
            guard let outline, outline.clickedRow >= 0, let node = outline.item(atRow: outline.clickedRow) as? FileNode else { return }
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
                    switch result {
                    case .success(let entries):
                        let old = Dictionary(uniqueKeysWithValues: (node.children ?? []).map { ($0.url, $0) })
                        node.children = entries.map { old[$0.0] ?? FileNode(url: $0.0, isDirectory: $0.1) }
                        self.outline?.reloadItem(node, reloadChildren: true)
                        self.restoreExpansion(node)
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
            if node.isDirectory {
                let new = NSMenuItem(title: "Nuevo archivo…", action: #selector(newFile(_:)), keyEquivalent: "")
                new.target = self
                new.representedObject = node
                menu.addItem(new)
            }
            if let project = node.project {
                let command = NSMenuItem(title: "Comando…", action: #selector(editCommand(_:)), keyEquivalent: "")
                command.target = self
                command.representedObject = project
                menu.addItem(command)
                menu.addItem(.separator())
                let remove = NSMenuItem(title: "Quitar del proyecto", action: #selector(removeRoot(_:)), keyEquivalent: "")
                remove.target = self
                remove.representedObject = project
                menu.addItem(remove)
            }
        }

        @objc func newFile(_ item: NSMenuItem) {
            if let node = item.representedObject as? FileNode { controller.files.create(in: node.url) }
        }
        @objc func editCommand(_ item: NSMenuItem) { controller.commandProject = item.representedObject as? CodeProject }
        @objc func removeRoot(_ item: NSMenuItem) {
            if let project = item.representedObject as? CodeProject { controller.projects.remove(project.id) } }
    }
}
