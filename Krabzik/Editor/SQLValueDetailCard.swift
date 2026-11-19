import AppKit

/// NSTableView recicla las celdas: abrir una lista de 10.000 valores no crea 10.000 vistas.
@MainActor final class SQLValueDetailCard: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    let detail: SQLValueDetail
    let search = NSSearchField()
    let table = NSTableView()
    let copyButton = NSButton(title: "Copiar valores", target: nil, action: nil)
    private let footer = NSTextField(labelWithString: "")
    private let empty = NSTextField(labelWithString: "Sin coincidencias")
    private(set) var displayedRows: [SQLValueDetail.Row]
    var close: (() -> Void)?
    private var copyFeedback: DispatchWorkItem?
    /// Punto de inyección para no modificar el portapapeles del usuario en XCTest.
    var writeClipboard: (String) -> Void = { text in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    init(value: SQLSetValue) {
        let detail = SQLValueDetail(value)
        self.detail = detail
        self.displayedRows = detail.rows
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: 380, height: max(240, min(420, 185 + CGFloat(detail.rows.count) * 27)))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = NSVisualEffectView(frame: NSRect(origin: .zero, size: preferredContentSize))
        root.material = .popover
        root.blendingMode = .withinWindow
        root.state = .active
        view = root
        let title = NSTextField(labelWithString: detail.title)
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.lineBreakMode = .byTruncatingMiddle
        title.toolTip = detail.title
        let subtitle = NSTextField(labelWithString: detail.subtitle)
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        subtitle.toolTip = detail.origin
        let dismiss = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Cerrar detalle") ?? NSImage(),
                               target: self, action: #selector(dismissCard))
        dismiss.isBordered = false
        dismiss.toolTip = "Cerrar detalle (Esc)"
        dismiss.setAccessibilityLabel("Cerrar detalle de valores")
        search.placeholderString = "Filtrar valores…"
        search.setAccessibilityLabel("Filtrar valores de " + detail.title)
        search.toolTip = "Buscar entre los valores capturados"
        search.sendsSearchStringImmediately = true
        search.sendsWholeSearchString = false
        search.delegate = self
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = false
        scroll.scrollerStyle = .legacy
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = false
        table.backgroundColor = .clear
        table.gridStyleMask = .solidHorizontalGridLineMask
        table.gridColor = .separatorColor
        table.rowHeight = 27
        table.intercellSpacing = NSSize(width: 8, height: 0)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.allowsMultipleSelection = true
        table.setAccessibilityLabel("Valores de " + detail.title)
        let index = NSTableColumn(identifier: .init("index"))
        index.title = "#"
        index.width = 50
        index.minWidth = 50
        index.maxWidth = 50
        let value = NSTableColumn(identifier: .init("value"))
        value.title = "Valor"
        value.width = 270
        value.minWidth = 140
        for column in [index, value] {
            column.headerCell.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        scroll.documentView = table
        copyButton.target = self
        copyButton.action = #selector(copyValues)
        copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        copyButton.imagePosition = .imageLeading
        copyButton.bezelStyle = .rounded
        footer.font = .systemFont(ofSize: 11)
        footer.textColor = .secondaryLabelColor
        footer.lineBreakMode = .byTruncatingTail
        footer.toolTip = detail.origin ?? detail.footer
        empty.font = .systemFont(ofSize: 13)
        empty.textColor = .secondaryLabelColor
        for child in [title, subtitle, dismiss, search, scroll, empty, copyButton, footer] {
            child.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(child)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            title.trailingAnchor.constraint(lessThanOrEqualTo: dismiss.leadingAnchor, constant: -8),
            dismiss.topAnchor.constraint(equalTo: root.topAnchor, constant: 13),
            dismiss.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            dismiss.widthAnchor.constraint(equalToConstant: 24), dismiss.heightAnchor.constraint(equalToConstant: 24),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 5),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            search.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 14),
            search.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            search.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            search.heightAnchor.constraint(equalToConstant: 28),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: search.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: copyButton.topAnchor, constant: -12),
            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            copyButton.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            copyButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
            copyButton.widthAnchor.constraint(equalToConstant: 134), copyButton.heightAnchor.constraint(equalToConstant: 28),
            footer.leadingAnchor.constraint(equalTo: copyButton.trailingAnchor, constant: 10),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            footer.centerYAnchor.constraint(equalTo: copyButton.centerYAnchor)
        ])
        updateFilter()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(search)
    }
    func controlTextDidChange(_ notification: Notification) { updateFilter() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        dismissCard()
        return true
    }
    func updateFilter() {
        copyFeedback?.cancel()
        displayedRows = detail.filtered(search.stringValue)
        table.reloadData()
        table.deselectAll(nil)
        copyButton.title = search.stringValue.isEmpty ? "Copiar valores" : "Copiar filtrados"
        copyButton.isEnabled = !displayedRows.isEmpty
        copyButton.toolTip = "Copiar \(displayedRows.count) valores como lista SQL, separados por comas"
        footer.stringValue = search.stringValue.isEmpty ? detail.footer : "\(displayedRows.count) de \(detail.rows.count) valores"
        empty.stringValue = detail.rows.isEmpty ? "Sin valores disponibles" : "Sin coincidencias"
        empty.isHidden = !displayedRows.isEmpty
    }
    @objc func copyValues() {
        guard let text = SQLValueDetail.copyText(displayedRows) else { return }
        writeClipboard(text)
        copyButton.title = "Copiado"
        let feedback = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.copyButton.title = self.search.stringValue.isEmpty ? "Copiar valores" : "Copiar filtrados"
        }
        copyFeedback?.cancel()
        copyFeedback = feedback
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: feedback)
    }
    @objc private func dismissCard() { close?() }
    func numberOfRows(in tableView: NSTableView) -> Int { displayedRows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn, displayedRows.indices.contains(row) else { return nil }
        let field = tableView.makeView(withIdentifier: column.identifier, owner: self) as? NSTextField
            ?? NSTextField(labelWithString: "")
        field.identifier = column.identifier
        let item = displayedRows[row]
        let index = column.identifier.rawValue == "index"
        field.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        field.textColor = index ? .secondaryLabelColor : .labelColor
        field.alignment = index ? .right : .left
        field.lineBreakMode = .byTruncatingTail
        field.stringValue = index ? String(item.index) : item.value.replacingOccurrences(of: "\r\n", with: "↵")
            .replacingOccurrences(of: "\n", with: "↵").replacingOccurrences(of: "\r", with: "↵")
        field.toolTip = index ? nil : item.value
        field.setAccessibilityLabel(index ? "Fila \(item.index)" : "Valor \(item.index)")
        field.setAccessibilityValue(index ? String(item.index) : item.value)
        return field
    }
    func invalidate() { copyFeedback?.cancel()
    copyFeedback = nil
    close = nil }
}
