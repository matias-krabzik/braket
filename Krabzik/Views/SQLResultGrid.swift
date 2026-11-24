import SwiftUI

final class SQLGridTable: NSTableView {
    var pasteboard = NSPasteboard.general
    var copySelection: (() -> Bool)?
    var pasteSelection: (() -> Bool)?
    var canCopySelection: (() -> Bool)?
    var canPasteSelection: (() -> Bool)?

    @objc func copy(_ sender: Any?) { _ = copySelection?() }
    @objc func paste(_ sender: Any?) { _ = pasteSelection?() }
    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)): canCopySelection?() == true
        case #selector(paste(_:)): canPasteSelection?() == true
        default: super.validateUserInterfaceItem(item)
        }
    }
    private func handleClipboard(_ event: NSEvent) -> Bool {
        guard window?.firstResponder === self, let action = SQLCellClipboard.action(for: event) else { return false }
        switch action {
        case .copy: copy(nil)
        case .paste: paste(nil)
        }
        return true
    }

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

    var navigate: ((UInt16, Bool) -> Void)?
    var editSelected: (() -> Void)?
    var review: (() -> Void)?
    var contextualMenu: ((Int, Int) -> NSMenu)?
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point), column = column(at: point)
        guard row >= 0, column >= 0 else { return nil }
        selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        return contextualMenu?(row, column)
    }
    override func mouseDown(with event: NSEvent) {
        if let editor = SQLCellEditorController.active, editor.isEditing, editor.view.isDescendant(of: self) {
            let point = convert(event.locationInWindow, from: nil)
            let frame = editor.view.convert(editor.view.bounds, to: self)
            if !frame.contains(point), !editor.confirmValue() { return }
        }
        super.mouseDown(with: event)
    }
    override func keyDown(with event: NSEvent) {
        if handleClipboard(event) { return }
        if [123, 124, 125, 126, 48].contains(event.keyCode),
           event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            navigate?(event.keyCode, event.modifierFlags.contains(.shift))
            return
        }
        if [36, 76].contains(event.keyCode), !event.modifierFlags.contains(.command) {
            editSelected?()
            return
        }
        super.keyDown(with: event)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleClipboard(event) { return true }
        if event.modifierFlags.contains(.command), event.keyCode == 36, Self.reviewFocusedGrid() { return true }
        return super.performKeyEquivalent(with: event)
    }
    static func reviewFocusedGrid() -> Bool {
        if let editor = SQLCellEditorController.active, editor.isEditing {
            editor.commandEnter()
            return true
        }
        let responder = NSApp.keyWindow?.firstResponder
        var view = responder as? NSView
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

private final class SQLGridCellView: NSTableCellView {
    let valueLabel = SQLGridField()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        valueLabel.cell = SQLGridTextCell(textCell: "")
        valueLabel.frame = bounds
        valueLabel.autoresizingMask = [.width, .height]
        addSubview(valueLabel)
        textField = valueLabel
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
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
    var serverNow: (@MainActor (SQLSchemaColumn) async throws -> String)?
    func makeCoordinator() -> Coordinator { Coordinator(draft: draft) }
    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.cellEditor?.cancelEditing()
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
        table.selectionHighlightStyle = .none
        table.allowsMultipleSelection = false
        table.navigate = { [weak coordinator = context.coordinator] key, shift in coordinator?.navigate(key: key, shift: shift) }
        table.editSelected = { [weak coordinator = context.coordinator] in coordinator?.editSelectedCell() }
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
        table.copySelection = { [weak coordinator = context.coordinator] in coordinator?.copySelectedValue() ?? false }
        table.pasteSelection = { [weak coordinator = context.coordinator] in coordinator?.pasteSelectedValue() ?? false }
        table.canCopySelection = { [weak coordinator = context.coordinator] in coordinator?.canCopySelectedValue == true }
        table.canPasteSelection = { [weak coordinator = context.coordinator] in coordinator?.canPasteSelectedValue == true }
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
            coordinator.cellEditor?.cancelEditing()
            coordinator.draft.scrollOrigin = Self.scrollOffset(in: scroll)
            coordinator.restoredScroll = false
        }
        coordinator.draft = draft
        coordinator.scale = scale
        coordinator.theme = theme
        coordinator.serverNow = serverNow
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
            if coordinator.editing && coordinator.editingColumn == index { continue }
            let width = draft.widths[index].map { $0 * scale }
                ?? Self.preferredWidth(for: index, in: draft, font: font, scale: scale)
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
        var cellEditor: SQLCellEditorController?
        var serverNow: (@MainActor (SQLSchemaColumn) async throws -> String)?
        var editingColumn: Int?
        var editingOriginalWidth: CGFloat?
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
        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            if editing, let cell = draft.selectedCell, cell.row == modelRow(row), let editor = cellEditor {
                return max(27 * scale, editor.desiredHeight)
            }
            return 27 * scale
        }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let column = Int(tableColumn?.identifier.rawValue ?? ""), row < draft.rowCount else { return nil }
            let row = modelRow(row)
            let identifier = NSUserInterfaceItemIdentifier("value")
            let cell = (tableView.makeView(withIdentifier: identifier, owner: nil) as? SQLGridCellView)
                ?? SQLGridCellView(frame: .zero)
            cell.identifier = identifier
            let field = cell.valueLabel
            field.isHidden = false
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
            field.toolTip = value.display + "\nFlechas: navegar · ⌘C: copiar · ⌘V: pegar"
                + " · Enter: editar · ⌘Enter: revisar cambios"
            field.setAccessibilityLabel(draft.result.columns[column] + ", fila \(visibleRow(row) + 1)")
            return cell
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
            select(row: modelRow(sender.clickedRow), column: sender.clickedColumn)
        }
        @objc func editCell(_ sender: NSTableView) {
            guard sender.clickedRow >= 0 else { return }
            beginEditing(row: modelRow(sender.clickedRow), column: sender.clickedColumn)
        }
        func select(row: Int, column: Int) {
            guard let table, (0..<draft.rowCount).contains(row), table.tableColumns.indices.contains(column) else { return }
            draft.selectedCell = SQLCell(row: row, column: column)
            table.selectRowIndexes(IndexSet(integer: visibleRow(row)), byExtendingSelection: false)
            table.scrollRowToVisible(visibleRow(row))
            table.scrollColumnToVisible(column)
            table.reloadData()
            table.window?.makeFirstResponder(table)
        }
        private var clipboardCell: SQLCell? {
            guard let cell = draft.selectedCell, (0..<draft.rowCount).contains(cell.row),
                  draft.result.columns.indices.contains(cell.column) else { return nil }
            let count = cell.row < draft.result.rows.count ? draft.result.rows[cell.row].count
                : draft.inserted[cell.row - draft.result.rows.count].count
            return cell.column < count ? cell : nil
        }
        var canCopySelectedValue: Bool { !editing && clipboardCell != nil }
        var canPasteSelectedValue: Bool {
            guard !editing, let cell = clipboardCell, let table,
                  draft.canEditCell(row: cell.row, column: cell.column), draft.column(cell.column) != nil else { return false }
            return table.pasteboard.availableType(from: [.string]) != nil
        }
        @discardableResult func copySelectedValue() -> Bool {
            guard canCopySelectedValue, let cell = clipboardCell, let table else { return false }
            SQLCellClipboard.write(draft.value(row: cell.row, column: cell.column), to: table.pasteboard)
            return true
        }
        @discardableResult func pasteSelectedValue() -> Bool {
            guard canPasteSelectedValue, let cell = clipboardCell, let column = draft.column(cell.column), let table,
                  let value = SQLCellClipboard.read(from: table.pasteboard) else { return false }
            do {
                let validated: SQLCellValue
                switch value {
                case .text(let text): validated = .text(try SQLCellInput.validate(text, column: column))
                case .null:
                    guard column.nullable else { throw DatabaseFailure("Este campo no admite NULL.") }
                    validated = .null
                case .serverDefault:
                    guard column.canDefault else { throw DatabaseFailure("Este campo no tiene DEFAULT.") }
                    validated = .serverDefault
                }
                draft.error = nil
                draft.set(validated, row: cell.row, column: cell.column)
                table.reloadData()
                return true
            } catch { draft.error = AppError.describe(error)
            return false }
        }
        func navigate(key: UInt16, shift: Bool = false) {
            guard !editing, let table, draft.rowCount > 0, !table.tableColumns.isEmpty else { return }
            guard let cell = draft.selectedCell, (0..<draft.rowCount).contains(cell.row) else { select(row: modelRow(0), column: 0)
            return }
            var row = visibleRow(cell.row), column = cell.column
            switch key {
            case 123: column = max(0, column - 1)
            case 124: column = min(table.tableColumns.count - 1, column + 1)
            case 125: row = min(draft.rowCount - 1, row + 1)
            case 126: row = max(0, row - 1)
            case 48:
                let current = row * table.tableColumns.count + column
                let next = max(0, min(draft.rowCount * table.tableColumns.count - 1, current + (shift ? -1 : 1)))
                row = next / table.tableColumns.count
                column = next % table.tableColumns.count
            default: return
            }
            select(row: modelRow(row), column: column)
        }
        func editSelectedCell() {
            guard let cell = draft.selectedCell else { select(row: modelRow(0), column: 0)
            if let cell = draft.selectedCell { beginEditing(row: cell.row, column: cell.column) }
            return }
            beginEditing(row: cell.row, column: cell.column)
        }
        func beginEditing(row: Int, column: Int) {
            guard !editing, let table, let metadata = draft.column(column), draft.canEditCell(row: row, column: column) else { return }
            select(row: row, column: column)
            guard let field = table.view(atColumn: column, row: visibleRow(row), makeIfNecessary: true),
                  draft.beginEditing(row: row, column: column) else { return }
            editing = true
            let editor = SQLCellEditorController(column: metadata, value: draft.value(row: row, column: column))
            editor.scale = scale
            editor.textView.pasteboard = table.pasteboard
            editor.serverNow = serverNow
            cellEditor = editor
            let tableColumn = table.tableColumns[column]
            editingColumn = column
            editingOriginalWidth = tableColumn.width
            let valueWidth = (draft.value(row: row, column: column).display as NSString)
                .size(withAttributes: [.font: Theme.nativeCodeFont(scale: scale)]).width + 24 * scale
            let required: CGFloat
            if case .temporal = metadata.cellKind { required = max(270 * scale, valueWidth + 80 * scale) }
            else { required = min(700 * scale, valueWidth) }
            if required > tableColumn.width {
                settingWidth = true
                tableColumn.width = min(tableColumn.maxWidth, required)
                settingWidth = false
            }
            table.scrollColumnToVisible(column)
            (field as? SQLGridCellView)?.valueLabel.isHidden = true
            editor.onResize = { [weak self, weak table] in
                guard let self, self.editing else { return }
                table?.noteHeightOfRows(withIndexesChanged: IndexSet(integer: self.visibleRow(row)))
            }
            editor.onFinish = { [weak self] value in
                guard let self else { return }
                self.draft.selectedCell = SQLCell(row: row, column: column)
                if self.draft.canEditCell(row: row, column: column) { self.draft.endEditing(commit: value) }
                else { self.draft.endEditing() }
                self.editing = false
                self.cellEditor = nil
                if let width = self.editingOriginalWidth, let index = self.editingColumn,
                   let table = self.table, table.tableColumns.indices.contains(index) {
                    self.settingWidth = true
                    table.tableColumns[index].width = width
                    self.settingWidth = false
                    table.noteHeightOfRows(withIndexesChanged: IndexSet(integer: self.visibleRow(row)))
                }
                self.editingColumn = nil
                self.editingOriginalWidth = nil
                self.table?.reloadData()
                self.table?.window?.makeFirstResponder(self.table)
            }
            editor.onAdvance = { [weak self] shift in self?.navigate(key: 48, shift: shift) }
            editor.show(relativeTo: field.bounds, of: field)
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
            add("Copiar valor", "copy", enabled: canCopySelectedValue)
            add("Pegar valor", "paste", enabled: canPasteSelectedValue)
            if !draft.canEdit { add(draft.reason.isEmpty ? "Edición no disponible" : draft.reason, "", enabled: false) }
            let metadata = draft.column(column)
            add("Editar celda", "edit", enabled: draft.canEdit && metadata?.generated != true && !draft.deleted.contains(row))
            if draft.canEdit, metadata?.generated != true, !draft.deleted.contains(row) {
                if metadata?.nullable == true { add("Poner en NULL", "null") }
                if metadata?.canDefault == true { add("Usar DEFAULT", "default") }
                if case .temporal = metadata?.cellKind { add("Fecha/hora actual del servidor", "now") }
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
                copySelectedValue()
            case "paste":
                pasteSelectedValue()
            case "edit":
                beginEditing(row: menuRow, column: menuColumn)
                return
            case "now":
                beginEditing(row: menuRow, column: menuColumn)
                cellEditor?.useNow()
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
