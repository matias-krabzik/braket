import SwiftUI

final class SQLGridTable: NSTableView {
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
}

struct SQLResultGrid: NSViewRepresentable {
    let draft: SQLResultDraft
    let scale: Double
    let theme: AppTheme
    func makeCoordinator() -> Coordinator { Coordinator(draft: draft) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        let table = SQLGridTable()
        table.style = .plain
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.intercellSpacing = NSSize(width: 12, height: 0)
        table.gridStyleMask = [.solidVerticalGridLineMask, .solidHorizontalGridLineMask]
        table.gridColor = .separatorColor.withAlphaComponent(0.2)
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.target = context.coordinator
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
        coordinator.draft = draft
        coordinator.scale = scale
        // Observe the pending values even while the table owns its field editor.
        _ = draft.changes
        _ = draft.inserted
        _ = draft.deleted
        _ = draft.sent
        _ = draft.reason
        table.backgroundColor = EditorPalette.background(for: theme)
        table.rowHeight = 28 * scale
        if changedResult {
            for column in table.tableColumns { table.removeTableColumn(column) }
            for (index, name) in draft.result.columns.enumerated() {
                let column = NSTableColumn(identifier: .init("\(index)"))
                column.title = name
                column.minWidth = 44
                column.maxWidth = 4000
                column.resizingMask = .userResizingMask
                table.addTableColumn(column)
            }
        }
        for (index, column) in table.tableColumns.enumerated() {
            let font = NSFont.monospacedSystemFont(ofSize: 12 * scale, weight: .medium)
            column.headerCell.font = font
            let initial = (column.title as NSString).size(withAttributes: [.font: font]).width + 28 * scale
            let width = draft.widths[index].map { $0 * scale } ?? max(54 * scale, initial)
            if abs(column.width - width) > 0.5 { coordinator.settingWidth = true
            column.width = width
            coordinator.settingWidth = false }
        }
        if !coordinator.editing { table.reloadData() }
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDelegate, NSTableViewDataSource, NSTextFieldDelegate {
        var draft: SQLResultDraft
        var scale = 1.0
        weak var table: SQLGridTable?
        var editing = false
        var settingWidth = false
        private var menuRow = 0, menuColumn = 0
        init(draft: SQLResultDraft) { self.draft = draft }
        func numberOfRows(in tableView: NSTableView) -> Int { draft.rowCount }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let column = Int(tableColumn?.identifier.rawValue ?? ""), row < draft.rowCount else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("value")
            let field = (tableView.makeView(withIdentifier: identifier, owner: nil) as? SQLGridField) ?? SQLGridField()
            let value = draft.value(row: row, column: column)
            field.identifier = identifier
            field.rowIndex = row
            field.columnIndex = column
            field.delegate = self
            field.stringValue = value.display
            field.isBordered = false
            field.drawsBackground = false
            field.isEditable = false
            field.isSelectable = false
            field.font = .monospacedSystemFont(ofSize: 12 * scale, weight: .regular)
            let pending = draft.changes[SQLCell(row: row, column: column)] != nil || row >= draft.result.rows.count
            field.textColor = draft.deleted.contains(row) ? .systemRed : pending ? .systemOrange
                : value == .null || value == .serverDefault ? .tertiaryLabelColor : EditorPalette.text
            field.lineBreakMode = .byTruncatingTail
            field.toolTip = value.display
            return field
        }
        func tableViewColumnDidResize(_ notification: Notification) {
            guard !settingWidth, let column = notification.userInfo?["NSTableColumn"] as? NSTableColumn,
                  let index = Int(column.identifier.rawValue) else { return }
            draft.widths[index] = column.width / scale
        }
        @objc func editCell(_ sender: NSTableView) {
            beginEditing(row: sender.clickedRow, column: sender.clickedColumn)
        }
        private func beginEditing(row: Int, column: Int) {
            guard let sender = table, draft.canEdit, row >= 0, column >= 0, !draft.deleted.contains(row),
                  draft.column(column)?.generated != true,
                  let field = sender.view(atColumn: column, row: row, makeIfNecessary: true) as? SQLGridField else { return }
            field.isEditable = true
            field.isSelectable = true
            if draft.value(row: row, column: column) == .null || draft.value(row: row, column: column) == .serverDefault {
                field.stringValue = ""
            }
            editing = true
            SQLGridTable.editingField = field
            field.selectText(nil)
        }
        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? SQLGridField, editing else { return }
            draft.set(.text(field.stringValue), row: field.rowIndex, column: field.columnIndex)
            editing = false
            SQLGridTable.editingField = nil
            field.isEditable = false
            table?.reloadData()
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                table?.window?.makeFirstResponder(table)
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                editing = false
                table?.window?.makeFirstResponder(table)
                table?.reloadData()
                return true
            }
            return false
        }
        func menu(row: Int, column: Int) -> NSMenu {
            table?.window?.makeFirstResponder(table)
            menuRow = row
            menuColumn = column
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
