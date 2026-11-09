import AppKit
import SwiftUI

@MainActor final class FileNode: NSObject {
    let url: URL
    let name: String
    let isDirectory: Bool
    let project: CodeProject?
    var children: [FileNode]?
    var loading = false
    var watcher: DispatchSourceFileSystemObject?

    init(url: URL, isDirectory: Bool, project: CodeProject? = nil) {
        self.url = url
        self.name = project?.name ?? url.lastPathComponent
        self.isDirectory = isDirectory
        self.project = project
    }

    deinit { watcher?.cancel() }
}

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
        let outline = NSOutlineView()
        let column = NSTableColumn(identifier: .init("files"))
        column.minWidth = 180
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowHeight = 29
        outline.indentationPerLevel = 14
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

    @MainActor final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
        weak var outline: NSOutlineView?
        let controller: WorkspaceController
        var roots: [FileNode] = []
        var lastRevision = -1
        var lastURL: URL?
        var generation = UUID()
        private let queue = DispatchQueue(label: "com.krabzik.files", qos: .userInitiated)
        nonisolated private static let excluded: Set<String> = [".git", "node_modules", "vendor", ".build", "DerivedData", "dist", ".next", ".angular", ".DS_Store"]

        init(controller: WorkspaceController) { self.controller = controller }

        func update(_ workspace: Workspace, at url: URL, revision: Int) {
            guard revision != lastRevision || url != lastURL else { return }
            let sameWorkspace = lastURL == url
            lastRevision = revision
            lastURL = url
            if !sameWorkspace { generation = UUID() }
            let previous = sameWorkspace ? Dictionary(uniqueKeysWithValues: roots.map { ($0.url, $0) }) : [:]
            roots = workspace.projects.map { project in
                let directory = project.directory(relativeTo: url)
                if let node = previous[directory], node.project == project { return node }
                return FileNode(url: directory, isDirectory: true, project: project)
            }
            outline?.reloadData()
            for root in roots {
                if root.children == nil { load(root) }
                else { outline?.expandItem(root) }
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
            if let node = item as? FileNode, node.children == nil { load(node) }
            return true
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? FileNode else { return nil }
            let cell = NSTableCellView()
            let icon = NSImageView()
            icon.image = NSImage(systemSymbolName: node.isDirectory ? "folder.fill" : fileSymbol(node.url), accessibilityDescription: nil)
            icon.contentTintColor = node.isDirectory ? NSColor(calibratedRed: 0.49, green: 0.68, blue: 0.87, alpha: 1) : .secondaryLabelColor
            let label = NSTextField(labelWithString: node.name)
            label.font = .systemFont(ofSize: 12, weight: node.project == nil ? .regular : .medium)
            label.lineBreakMode = .byTruncatingMiddle
            let detail = NSTextField(labelWithString: node.project?.kind.rawValue ?? "")
            detail.font = .systemFont(ofSize: 10)
            detail.textColor = .tertiaryLabelColor
            detail.setContentCompressionResistancePriority(.required, for: .horizontal)
            let stack = NSStackView(views: [icon, label, detail])
            stack.orientation = .horizontal
            stack.spacing = 7
            stack.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
                stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 15), icon.heightAnchor.constraint(equalToConstant: 15)
            ])
            cell.textField = label
            cell.imageView = icon
            cell.toolTip = node.url.path
            return cell
        }

        private func fileSymbol(_ url: URL) -> String {
            ["swift", "php", "ts", "js", "jsx", "tsx", "html", "css", "astro", "sql"].contains(url.pathExtension) ? "chevron.left.forwardslash.chevron.right" : "doc"
        }

        @objc func clicked() {
            guard let outline, outline.clickedRow >= 0, let node = outline.item(atRow: outline.clickedRow) as? FileNode else { return }
            if !node.isDirectory { controller.openFile(node.url) }
        }

        private func load(_ node: FileNode) {
            guard !node.loading else { return }
            node.loading = true
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
                        if node.project != nil { self.outline?.expandItem(node) }
                        self.watch(node)
                    case .failure(let error):
                        node.children = []
                        self.outline?.reloadItem(node)
                        self.controller.show(error)
                    }
                }
            }
        }

        private func watch(_ node: FileNode) {
            guard node.watcher == nil else { return }
            let fd = open(node.url.path, O_EVTONLY)
            guard fd >= 0 else { return }
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
                new.target = self; new.representedObject = node
                menu.addItem(new)
            }
            if let project = node.project {
                let command = NSMenuItem(title: "Comando…", action: #selector(editCommand(_:)), keyEquivalent: "")
                command.target = self; command.representedObject = project
                menu.addItem(command)
                menu.addItem(.separator())
                let remove = NSMenuItem(title: "Quitar del proyecto", action: #selector(removeRoot(_:)), keyEquivalent: "")
                remove.target = self; remove.representedObject = project
                menu.addItem(remove)
            }
        }

        @objc func newFile(_ item: NSMenuItem) { if let node = item.representedObject as? FileNode { controller.createFile(in: node.url) } }
        @objc func editCommand(_ item: NSMenuItem) { controller.commandProject = item.representedObject as? CodeProject }
        @objc func removeRoot(_ item: NSMenuItem) { if let project = item.representedObject as? CodeProject { controller.removeProject(project.id) } }
    }
}
