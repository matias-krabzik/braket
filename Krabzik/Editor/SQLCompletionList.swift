import AppKit

/// An editor-owned suggestion list avoids TextKit's provisional replacement of qualified SQL names.
@MainActor final class SQLCompletionList: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let scroll = NSScrollView()
    private let table = NSTableView()
    private var items: [String] = []
    var accept: ((String) -> Void)?
    var visible: Bool { !scroll.isHidden }

    override init() {
        super.init()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 6
        scroll.layer?.borderWidth = 1
        scroll.layer?.borderColor = NSColor.separatorColor.cgColor
        scroll.isHidden = true
        table.headerView = nil
        table.rowHeight = 25
        table.style = .plain
        table.backgroundColor = .windowBackgroundColor
        let column = NSTableColumn(identifier: .init("suggestion"))
        column.width = 300
        table.addTableColumn(column)
        table.delegate = self
        table.dataSource = self
        table.target = self
        table.action = #selector(choose)
        table.setAccessibilityLabel("Sugerencias SQL")
        scroll.documentView = table
    }

    func show(_ values: [String], in surface: NSView, textView: NSTextView) {
        guard !values.isEmpty, let window = surface.window else { hide()
        return }
        items = values
        if scroll.superview == nil { surface.addSubview(scroll) }
        let caret = textView.firstRect(forCharacterRange: textView.selectedRange(), actualRange: nil)
        let local = surface.convert(window.convertFromScreen(caret), from: nil)
        let width = min(360.0, surface.bounds.width)
        let height = min(200.0, Double(values.count) * 25 + 4)
        scroll.frame = NSRect(x: min(max(0, local.minX), max(0, surface.bounds.width - width)),
                              y: max(0, local.minY - height - 3), width: width, height: height)
        table.tableColumns.first?.width = width - 18
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        table.scrollRowToVisible(0)
        scroll.isHidden = false
    }

    func hide() { scroll.isHidden = true }

    func handle(_ event: NSEvent) -> Bool {
        guard visible, event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        switch event.keyCode {
        case 53: hide()
        case 36, 48: choose()
        case 125, 126:
            let row = min(items.count - 1, max(0, table.selectedRow + (event.keyCode == 125 ? 1 : -1)))
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
        default: return false
        }
        return true
    }

    @objc private func choose() {
        guard items.indices.contains(table.selectedRow) else { return }
        let value = items[table.selectedRow]
        hide()
        accept?(value)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("suggestion")
        let label = (tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTextField)
            ?? NSTextField(labelWithString: "")
        label.identifier = identifier
        label.stringValue = items[row]
        label.font = .monospacedSystemFont(ofSize: Theme.zoom(12), weight: .regular)
        label.lineBreakMode = .byTruncatingTail
        return label
    }
}
