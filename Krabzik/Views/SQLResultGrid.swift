import SwiftUI

final class SQLGridTable: NSTableView {
    override func drawGrid(inClipRect clipRect: NSRect) {
        guard numberOfRows > 0 else { return }
        let rowsRect = NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width,
                              height: rect(ofRow: numberOfRows - 1).maxY - bounds.minY)
        let visibleGrid = clipRect.intersection(rowsRect)
        guard !visibleGrid.isEmpty else { return }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: visibleGrid).addClip()
        super.drawGrid(inClipRect: visibleGrid)
        NSGraphicsContext.restoreGraphicsState()
    }

    static weak var editingField: SQLGridField?
    var review: (() -> Void)?
    var contextualMenu: ((Int, Int) -> NSMenu)?
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point), column = column(at: point)
        guard row >= 0, column >= 0 else { return nil }
        selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        return contextualMenu?(row, column)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.keyCode == 36, Self.reviewFocusedGrid() { return true }
        return super.performKeyEquivalent(with: event)
    }
    static func reviewFocusedGrid() -> Bool {
        let responder = NSApp.keyWindow?.firstResponder
        var view = responder as? NSView
        if let field = editingField, field.currentEditor() === responder { view = field }
        while let current = view {
            if let table = current as? SQLGridTable {
                table.window?.makeFirstResponder(table)
                table.review?()
                return true
            }
            view = current.superview
        }
        return false
    }
}

final class SQLGridField: NSTextField {
    var rowIndex = 0
    var columnIndex = 0
    var gridFillColor: NSColor = .clear

    override func draw(_ dirtyRect: NSRect) {
        gridFillColor.setFill()
        bounds.fill()
        super.draw(dirtyRect)
    }
}

/// AppKit keeps legacy scrollers in the layout for subclasses that do not opt in to overlay scrollers.
private final class SQLGridScroller: NSScroller {}

private final class SQLGridScrollView: NSScrollView {
    override func tile() {
        super.tile()
        let gutter = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
        var viewport = contentView.frame
        viewport.size.width = min(viewport.width, max(0, bounds.width - gutter))
        viewport.size.height = min(viewport.height, max(0, bounds.height - gutter))
        contentView.frame = viewport
    }
}

private final class SQLGridHeaderCell: NSTableHeaderCell {
    var leadingInset: CGFloat = 8

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        super.drawInterior(withFrame: cellFrame.insetBy(dx: leadingInset, dy: 0), in: controlView)
    }
}

private final class SQLGridTextCell: NSTextFieldCell {
    private func centeredRect(in bounds: NSRect) -> NSRect {
        let content = super.drawingRect(forBounds: bounds)
        let fontHeight = ceil((font?.ascender ?? 0) - (font?.descender ?? 0) + (font?.leading ?? 0)) + 2
        let height = min(content.height, fontHeight)
        return NSRect(x: content.minX + 4, y: bounds.midY - height / 2,
                      width: max(0, content.width - 8), height: height)
    }

    override func drawingRect(forBounds rect: NSRect) -> NSRect { centeredRect(in: rect) }
}

struct SQLResultGrid: NSViewRepresentable {
    let draft: SQLResultDraft
    let scale: Double
    let theme: AppTheme
    func makeCoordinator() -> Coordinator { Coordinator(draft: draft) }
    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.draft.scrollOrigin = scrollOffset(in: scroll)
    }
    static func scrollOffset(in scroll: NSScrollView) -> NSPoint {
        let clip = scroll.contentView
        return NSPoint(x: clip.bounds.minX + clip.contentInsets.left,
                       y: clip.bounds.minY + clip.contentInsets.top)
    }

    static func restoreScrollOffset(_ offset: NSPoint, in scroll: NSScrollView) {
        scroll.layoutSubtreeIfNeeded()
        let clip = scroll.contentView
        // AppKit places the table header in the clip view's top inset. Logical
        // offset zero must include that inset so the first row stays below it.
        clip.scroll(to: NSPoint(x: offset.x - clip.contentInsets.left,
                                y: offset.y - clip.contentInsets.top))
        scroll.reflectScrolledClipView(clip)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = SQLGridScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.verticalScroller = SQLGridScroller()
        scroll.horizontalScroller = SQLGridScroller()
        scroll.scrollerStyle = .legacy
        scroll.autohidesScrollers = false
        let table = SQLGridTable()
        table.style = .plain
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.intercellSpacing = .zero
        table.gridStyleMask = [.solidVerticalGridLineMask, .solidHorizontalGridLineMask]
        table.gridColor = .separatorColor.withAlphaComponent(0.2)
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.target = context.coordinator
        table.action = #selector(Coordinator.selectCell(_:))
        table.doubleAction = #selector(Coordinator.editCell(_:))
        context.coordinator.table = table
        table.review = { [weak coordinator = context.coordinator] in
            guard let draft = coordinator?.draft, draft.hasChanges else { return }
            draft.showingReview = true
        }
        table.contextualMenu = { [weak coordinator = context.coordinator] row, column in
            coordinator?.menu(row: row, column: column) ?? NSMenu()
        }
        scroll.documentView = table
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let table = scroll.documentView as? SQLGridTable else { return }
        let coordinator = context.coordinator
        let changedResult = coordinator.draft.result.id != draft.result.id || table.tableColumns.isEmpty
        if coordinator.draft !== draft {
            coordinator.draft.scrollOrigin = Self.scrollOffset(in: scroll)
            coordinator.restoredScroll = false
        }
        coordinator.draft = draft
        coordinator.scale = scale
        coordinator.theme = theme
        // Observe the pending values even while the table owns its field editor.
        _ = draft.changes
        _ = draft.inserted
        _ = draft.deleted
        _ = draft.sent
        _ = draft.reason
        _ = draft.selectedCell
        table.backgroundColor = EditorPalette.background(for: theme)
        table.rowHeight = 27 * scale
        if changedResult {
            for column in table.tableColumns { table.removeTableColumn(column) }
            for (index, name) in draft.result.columns.enumerated() {
                let column = NSTableColumn(identifier: .init("\(index)"))
                column.headerCell = SQLGridHeaderCell(textCell: name)
                column.minWidth = 44
                column.maxWidth = 4000
                column.resizingMask = .userResizingMask
                table.addTableColumn(column)
            }
        }
        for (index, column) in table.tableColumns.enumerated() {
            let font = Theme.nativeCodeFont(scale: scale, weight: .bold)
            column.headerCell.font = font
            (column.headerCell as? SQLGridHeaderCell)?.leadingInset = 8 * scale
            let width = draft.widths[index].map { $0 * scale }
                ?? Self.preferredWidth(for: index, in: draft, font: font, scale: scale)
            if coordinator.editing && coordinator.editingColumn == index { continue }
            if abs(column.width - width) > 0.5 { coordinator.settingWidth = true
            column.width = width
            coordinator.settingWidth = false }
        }
        if !coordinator.editing {
            table.reloadData()
            if draft.inserted.count > coordinator.insertedCount {
                table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                table.scrollRowToVisible(0)
            }
            coordinator.insertedCount = draft.inserted.count
        }
        if !coordinator.restoredScroll {
            coordinator.restoredScroll = true
            let origin = draft.scrollOrigin
            DispatchQueue.main.async {
                guard coordinator.draft === draft else { return }
                Self.restoreScrollOffset(origin, in: scroll)
            }
        }
    }

    /// El encabezado y las primeras filas determinan el ancho inicial; el usuario puede ajustarlo después.
    static func preferredWidth(for index: Int, in draft: SQLResultDraft, font: NSFont, scale: Double) -> CGFloat {
        let heading = (draft.result.columns[index] as NSString).size(withAttributes: [.font: font]).width
        let values = draft.result.rows.prefix(100).compactMap { row -> CGFloat? in
            guard index < row.count else { return nil }
            return ((row[index] ?? "NULL") as NSString).size(withAttributes: [.font: font]).width
        }
        return min(420 * scale, max(90 * scale, (max(heading, values.max() ?? 0) + 28 * scale)))
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDelegate, NSTableViewDataSource, NSTextFieldDelegate {
        var draft: SQLResultDraft
        var scale = 1.0
        var theme: AppTheme = .graphite
        weak var table: SQLGridTable?
        var editing = false
        var editingColumn: Int?
        var editingOriginalWidth: CGFloat?
        weak var editingTextView: NSTextView?
        var originalEditorInset: NSSize?
        var settingWidth = false
        var restoredScroll = false
        var insertedCount = 0
        private func modelRow(_ row: Int) -> Int {
            row < draft.inserted.count ? draft.rowCount - 1 - row : row - draft.inserted.count
        }
        private func visibleRow(_ row: Int) -> Int {
            row >= draft.result.rows.count ? draft.rowCount - 1 - row : row + draft.inserted.count
        }
        private var menuRow = 0, menuColumn = 0
        init(draft: SQLResultDraft) { self.draft = draft }
        func numberOfRows(in tableView: NSTableView) -> Int { draft.rowCount }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let column = Int(tableColumn?.identifier.rawValue ?? ""), row < draft.rowCount else { return nil }
            let row = modelRow(row)
            let identifier = NSUserInterfaceItemIdentifier("value")
            let field = (tableView.makeView(withIdentifier: identifier, owner: nil) as? SQLGridField) ?? {
                let field = SQLGridField()
                field.cell = SQLGridTextCell(textCell: "")
                return field
            }()
            let value = draft.value(row: row, column: column)
            field.identifier = identifier
            field.rowIndex = row
            field.columnIndex = column
            field.delegate = self
            field.stringValue = value.display
            field.isBordered = false
            field.drawsBackground = false
            field.gridFillColor = draft.selectedCell == SQLCell(row: row, column: column)
                ? NSColor.controlAccentColor.withAlphaComponent(0.23)
                : (visibleRow(row).isMultiple(of: 2) ? EditorPalette.background(for: theme)
                   : EditorPalette.background(for: theme).blended(withFraction: 0.04, of: .labelColor)
                     ?? EditorPalette.background(for: theme))
            field.isEditable = false
            field.isSelectable = false
            field.font = Theme.nativeCodeFont(scale: scale)
            let pending = draft.changes[SQLCell(row: row, column: column)] != nil || row >= draft.result.rows.count
            field.textColor = draft.deleted.contains(row) ? .systemRed : pending ? .systemOrange
                : value == .null || value == .serverDefault ? .tertiaryLabelColor : EditorPalette.text
            field.lineBreakMode = .byTruncatingTail
            field.usesSingleLineMode = true
            field.toolTip = value.display
            return field
        }
        func tableViewColumnDidResize(_ notification: Notification) {
            guard !settingWidth, let column = notification.userInfo?["NSTableColumn"] as? NSTableColumn,
                  let index = Int(column.identifier.rawValue) else { return }
            draft.widths[index] = column.width / scale
            QAProbe.action("grid.column.resize", ["column": QAField.count(index),
                                                  "width": QAField.count(Int(column.width / scale)),
                                                  "result": QAField.text(draft.result.sql)])
        }
        @objc func selectCell(_ sender: NSTableView) {
            guard sender.clickedRow >= 0, sender.clickedColumn >= 0 else { return }
            draft.selectedCell = SQLCell(row: modelRow(sender.clickedRow), column: sender.clickedColumn)
        }
        @objc func editCell(_ sender: NSTableView) {
            guard sender.clickedRow >= 0 else { return }
            beginEditing(row: modelRow(sender.clickedRow), column: sender.clickedColumn)
        }
        private func beginEditing(row: Int, column: Int) {
            guard let sender = table, draft.canEditCell(row: row, column: column),
                  let field = sender.view(atColumn: column, row: visibleRow(row), makeIfNecessary: true) as? SQLGridField else { return }
            field.isEditable = true
            field.isSelectable = true
            if sender.tableColumns.indices.contains(column) {
                let tableColumn = sender.tableColumns[column]
                let fullWidth = (field.stringValue as NSString).size(withAttributes: [
                    .font: field.font ?? Theme.nativeCodeFont(scale: scale)
                ]).width + 32 * scale
                if fullWidth > tableColumn.width {
                    editingOriginalWidth = tableColumn.width
                    editingColumn = column
                    settingWidth = true
                    tableColumn.width = min(tableColumn.maxWidth, fullWidth)
                    settingWidth = false
                }
            }
            if draft.value(row: row, column: column) == .null || draft.value(row: row, column: column) == .serverDefault {
                field.stringValue = ""
            }
            draft.beginEditing(row: row, column: column)
            editing = true
            SQLGridTable.editingField = field
            field.selectText(nil)
            if let editor = field.currentEditor() as? NSTextView {
                editingTextView = editor
                originalEditorInset = editor.textContainerInset
                let font = field.font ?? Theme.nativeCodeFont(scale: scale)
                let lineHeight = ceil(font.ascender - font.descender + font.leading)
                editor.textContainerInset = NSSize(width: editor.textContainerInset.width,
                                                   height: max(0, (field.bounds.height - lineHeight) / 2))
            }
            sender.scrollColumnToVisible(column)
        }
        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? SQLGridField, editing else { return }
            draft.selectedCell = SQLCell(row: field.rowIndex, column: field.columnIndex)
            draft.endEditing(commit: .text(field.stringValue))
            editing = false
            SQLGridTable.editingField = nil
            restoreEditorInset()
            field.isEditable = false
            restoreEditingWidth()
            table?.reloadData()
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                table?.window?.makeFirstResponder(table)
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                editing = false
                draft.endEditing()
                SQLGridTable.editingField = nil
                restoreEditorInset()
                restoreEditingWidth()
                table?.window?.makeFirstResponder(table)
                table?.reloadData()
                return true
            }
            return false
        }
        private func restoreEditorInset() {
            if let inset = originalEditorInset { editingTextView?.textContainerInset = inset }
            editingTextView = nil
            originalEditorInset = nil
        }
        private func restoreEditingWidth() {
            defer { editingColumn = nil
            editingOriginalWidth = nil }
            guard let index = editingColumn, let width = editingOriginalWidth,
                  let table, table.tableColumns.indices.contains(index) else { return }
            let column = table.tableColumns[index]
            settingWidth = true
            column.width = width
            settingWidth = false
        }
        func menu(row: Int, column: Int) -> NSMenu {
            let row = modelRow(row)
            table?.window?.makeFirstResponder(table)
            menuRow = row
            menuColumn = column
            draft.selectedCell = SQLCell(row: row, column: column)
            let menu = NSMenu()
            func add(_ title: String, _ action: String, enabled: Bool = true) {
                let item = NSMenuItem(title: title, action: #selector(menuAction(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = action
                item.isEnabled = enabled
                menu.addItem(item)
            }
            menu.autoenablesItems = false
            add("Copiar valor", "copy")
            if !draft.canEdit { add(draft.reason.isEmpty ? "Edición no disponible" : draft.reason, "", enabled: false) }
            let metadata = draft.column(column)
            add("Editar celda", "edit", enabled: draft.canEdit && metadata?.generated != true && !draft.deleted.contains(row))
            if draft.canEdit, metadata?.generated != true, !draft.deleted.contains(row) {
                if metadata?.nullable == true { add("Poner en NULL", "null") }
                if metadata?.canDefault == true { add("Usar DEFAULT", "default") }
                for value in metadata?.enumValues ?? [] { add(value, "enum:" + value) }
                add("Deshacer cambio de celda", "undo", enabled: draft.changes[SQLCell(row: row, column: column)] != nil)
            }
            menu.addItem(.separator())
            add("Agregar fila", "add", enabled: draft.canInsert)
            add("Duplicar fila", "duplicate", enabled: draft.canInsert)
            add(draft.deleted.contains(row) ? "Restaurar fila" : "Eliminar fila", "delete", enabled: draft.canEdit)
            add("Revisar todos los cambios…", "review", enabled: draft.hasChanges)
            return menu
        }
        @objc private func menuAction(_ item: NSMenuItem) {
            guard let action = item.representedObject as? String else { return }
            switch action {
            case "copy":
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(draft.value(row: menuRow, column: menuColumn).display, forType: .string)
            case "edit":
                beginEditing(row: menuRow, column: menuColumn)
                return
            case "null": draft.set(.null, row: menuRow, column: menuColumn)
            case "default": draft.set(.serverDefault, row: menuRow, column: menuColumn)
            case "undo": draft.changes.removeValue(forKey: SQLCell(row: menuRow, column: menuColumn))
            case "add": draft.addRow()
            case "duplicate": draft.addRow(duplicating: menuRow)
            case "delete": draft.deleteRow(menuRow)
            case "review": draft.showingReview = true
            default:
                if action.hasPrefix("enum:") { draft.set(.text(String(action.dropFirst(5))), row: menuRow, column: menuColumn) }
            }
            table?.reloadData()
        }
    }
}
