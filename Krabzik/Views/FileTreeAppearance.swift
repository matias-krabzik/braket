import AppKit

/// La celda ocupa todo el ancho; la sangría y el control +/− se dibujan explícitamente.
final class FileTreeOutlineView: NSOutlineView {
    var handleKey: ((NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if handleKey?(event) == true { return }
        super.keyDown(with: event)
    }

    override func canDragRows(with rowIndexes: IndexSet, at mouseDownPoint: NSPoint) -> Bool {
        // La celda personalizada contiene el botón +/−; no debe bloquear el
        // arrastre del nombre o del icono de toda la fila.
        return !rowIndexes.isEmpty && rowIndexes.allSatisfy { $0 >= 0 && $0 < numberOfRows }
    }

    override func frameOfOutlineCell(atRow row: Int) -> NSRect { .zero }

    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        var frame = super.frameOfCell(atColumn: column, row: row)
        frame.origin.x = 0
        frame.size.width = bounds.width
        return frame
    }

    func rootNode(for node: FileNode) -> FileNode {
        var root = node
        while let parent = parent(forItem: root) as? FileNode { root = parent }
        return root
    }

    func groupFrame(for node: FileNode) -> NSRect? {
        let root = rootNode(for: node)
        let firstRow = row(forItem: root)
        guard firstRow >= 0 else { return nil }
        var last = root
        while isItemExpanded(last), let child = last.children?.last { last = child }
        let lastRow = row(forItem: last)
        guard lastRow >= firstRow else { return nil }
        var frame = rect(ofRow: firstRow).union(rect(ofRow: lastRow))
        frame.origin.x = 24
        frame.size.width = max(0, bounds.width - 32)
        return frame.insetBy(dx: 0, dy: 2)
    }

}

final class FileTreeCell: NSTableCellView {
    private let disclosure = SidebarDisclosureButton()
    private var toggle: (() -> Void)?
    private var nodeName = ""

    init(node: FileNode, depth: Int, expanded: Bool, monochrome: Bool = false, toggle: @escaping () -> Void) {
        super.init(frame: .zero)
        self.toggle = toggle
        nodeName = node.name
        disclosure.target = self
        disclosure.action = #selector(toggleFolder)
        disclosure.translatesAutoresizingMaskIntoConstraints = false
        disclosure.isHidden = !node.isDirectory
        addSubview(disclosure)
        updateDisclosure(expanded)

        let icon = NSImageView()
        icon.imageScaling = .scaleProportionallyUpOrDown
        if let project = node.project {
            icon.image = FileIcons.project(project, automatic: node.projectIcon, monochrome: monochrome)
            if icon.image?.isTemplate == true { icon.contentTintColor = .labelColor }
        }
        else if node.isDirectory {
            if let name = FileIcons.folderTechnology(node.name, inFlutterProject: node.flutterProject),
               let technology = FileIcons.asset(name) {
                icon.image = FileIcons.display(technology, monochrome: monochrome)
                if icon.image?.isTemplate == true { icon.contentTintColor = .labelColor }
            } else {
                icon.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)
                icon.contentTintColor = EditorPalette.blue
            }
        } else {
            icon.image = FileIcons.display(FileIcons.file(node.url), monochrome: monochrome)
            if icon.image?.isTemplate == true { icon.contentTintColor = .labelColor }
        }
        let label = NSTextField(labelWithString: node.name)
        label.font = .systemFont(ofSize: 12, weight: node.project == nil ? .regular : .medium)
        label.lineBreakMode = .byTruncatingMiddle
        label.textColor = NSColor.labelColor
        let detail = NSTextField(labelWithString: node.project?.kind.rawValue ?? "")
        detail.font = .systemFont(ofSize: 10)
        detail.textColor = .tertiaryLabelColor
        detail.setContentCompressionResistancePriority(.required, for: .horizontal)
        let iconBackground = NSView()
        iconBackground.wantsLayer = true
        iconBackground.layer?.cornerRadius = 5
        icon.translatesAutoresizingMaskIntoConstraints = false
        iconBackground.addSubview(icon)
        let stack = NSStackView(views: [iconBackground, label, detail])
        stack.orientation = .horizontal
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let indent = CGFloat(depth) * SidebarTreeStyle.indent
        NSLayoutConstraint.activate([
            disclosure.leadingAnchor.constraint(equalTo: leadingAnchor, constant: indent + 8),
            disclosure.centerYAnchor.constraint(equalTo: centerYAnchor),
            disclosure.widthAnchor.constraint(equalToConstant: 16), disclosure.heightAnchor.constraint(equalToConstant: 18),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: indent + SidebarTreeStyle.iconLeading),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconBackground.widthAnchor.constraint(equalToConstant: 24), iconBackground.heightAnchor.constraint(equalToConstant: 24),
            icon.centerXAnchor.constraint(equalTo: iconBackground.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: iconBackground.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18), icon.heightAnchor.constraint(equalToConstant: 18)
        ])
        textField = label
        imageView = icon
        toolTip = node.url.path
    }

    required init?(coder: NSCoder) { super.init(coder: coder) }

    func updateDisclosure(_ expanded: Bool) {
        disclosure.update(expanded: expanded, name: nodeName)
    }

    @objc private func toggleFolder() { toggle?() }
}

/// Conectores de cada rama: la línea termina en el último hijo, sin cruzar al siguiente subproyecto.
final class FileTreeRow: NSTableRowView {
    weak var outline: NSOutlineView?
    weak var node: FileNode?

    // La selección usa un fondo tenue propio, no el relleno oscuro de AppKit.
    // `.emphasized` fuerza etiquetas e íconos blancos incluso en el tema claro.
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        drawGroupBackground()
        drawGuides()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard let outline, let node, selectionHighlightStyle != .none else { return }
        let leading = CGFloat(max(0, outline.level(forItem: node))) * 18 + 30
        let frame = NSRect(x: leading, y: 2, width: max(0, bounds.width - leading - 8),
                           height: max(0, bounds.height - 4))
        NSColor.labelColor.withAlphaComponent(isEmphasized ? 0.14 : 0.10).setFill()
        NSBezierPath(roundedRect: frame, xRadius: 5, yRadius: 5).fill()
        drawGuides()
    }

    private func drawGroupBackground() {
        guard let outline = outline as? FileTreeOutlineView, let node else { return }
        let root = outline.rootNode(for: node)
        guard let project = root.project, let tint = FileIcons.groupTint(project),
              let group = outline.groupFrame(for: root) else { return }
        let frame = convert(group, from: outline)
        NSGraphicsContext.saveGraphicsState()
        bounds.clip()
        tint.setFill()
        NSBezierPath(roundedRect: frame, xRadius: 7, yRadius: 7).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawGuides() {
        guard let outline, let node else { return }
        var chain = [node]
        while let parent = outline.parent(forItem: chain[0]) as? FileNode { chain.insert(parent, at: 0) }
        let ancestors = zip(chain, chain.dropFirst()).map { parent, child in parent.children?.last === child }
        let guides = SidebarTreeStyle.guides(ancestors: ancestors,
                                             expanded: outline.isItemExpanded(node) && !(node.children?.isEmpty ?? true),
                                             height: bounds.height)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        if !isFlipped {
            context.translateBy(x: 0, y: bounds.height)
            context.scaleBy(x: 1, y: -1)
        }
        context.setStrokeColor(NSColor.labelColor.withAlphaComponent(0.19).cgColor)
        context.setLineWidth(0.8)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setLineDash(phase: 0, lengths: [1, 3])
        context.addPath(guides)
        context.strokePath()
        context.restoreGState()
    }
}
