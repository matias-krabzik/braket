import AppKit

final class SQLCellTextView: NSTextView {
    var confirm: (() -> Void)?
    var cancel: (() -> Void)?
    var advance: ((Bool) -> Void)?
    var multiline = false
    var lostFocus: (() -> Void)?
    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { DispatchQueue.main.async { [weak self] in self?.lostFocus?() } }
        return accepted
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if [36, 76].contains(event.keyCode), event.modifierFlags.contains(.command) {
            commandEnter()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    func commandEnter() {
        if multiline { insertText("\n", replacementRange: selectedRange()) } else { NSSound.beep() }
    }

    override func keyDown(with event: NSEvent) {
        if [36, 76].contains(event.keyCode), !hasMarkedText() {
            if event.modifierFlags.contains(.command) { commandEnter() } else { confirm?() }
            return
        }
        if event.keyCode == 53 { cancel?()
        return }
        if event.keyCode == 48 { advance?(event.modifierFlags.contains(.shift))
        return }
        super.keyDown(with: event)
    }
}

/// El editor se monta dentro de la celda; solo el calendario abre un desplegable.
final class SQLCellEditorController: NSViewController, NSTextViewDelegate, NSPopoverDelegate {
    static weak var active: SQLCellEditorController?
    let column: SQLSchemaColumn
    let original: SQLCellValue
    let textView = SQLCellTextView()
    let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let stack = NSStackView()
    private let bar = NSStackView()
    private let scroll = NSScrollView()
    private let picker = NSDatePicker()
    private let choices = NSPopUpButton()
    private var nowButton: NSButton?
    private var choiceValues: [SQLCellValue?] = []
    private var inputHeight: NSLayoutConstraint?
    private var calendarRoot: NSView?
    private var finished = false
    private var changed = false
    private var selectedChoice: SQLCellValue?
    private var clockTask: Task<Void, Never>?
    private(set) var loadingNow = false
    private(set) var desiredHeight: CGFloat = 27
    private(set) var popover: NSPopover?
    var scale = 1.0
    var serverNow: (@MainActor (SQLSchemaColumn) async throws -> String)?
    var onFinish: ((SQLCellValue?) -> Void)?
    var onAdvance: ((Bool) -> Void)?
    var onResize: (() -> Void)?
    var isEditing: Bool { !finished && isViewLoaded && view.superview != nil }

    init(column: SQLSchemaColumn, value: SQLCellValue) {
        self.column = column
        original = value
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 27 * scale))
        view.wantsLayer = true
        view.layer?.borderWidth = 1
        view.layer?.borderColor = NSColor.controlAccentColor.cgColor
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 1),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -1),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 1),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -1)
        ])
        bar.orientation = .horizontal
        bar.alignment = .top
        bar.spacing = 2
        stack.addArrangedSubview(bar)
        bar.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        if case .enumeration(let values) = column.cellKind { buildChoices(values) }
        else {
            buildText()
            if case .temporal = column.cellKind {
                let calendar = NSButton(image: NSImage(systemSymbolName: "calendar", accessibilityDescription: "Elegir fecha u hora")
                                         ?? NSImage(), target: self, action: #selector(showCalendar))
                calendar.bezelStyle = .inline
                calendar.toolTip = "Elegir una fecha u hora"
                calendar.widthAnchor.constraint(equalToConstant: 24 * scale).isActive = true
                bar.addArrangedSubview(calendar)
                let now = NSButton(title: "Ahora", target: self, action: #selector(useNow))
                now.bezelStyle = .inline
                now.font = .systemFont(ofSize: 11 * scale)
                now.toolTip = "Consultar la fecha y hora de esta sesión MySQL"
                now.widthAnchor.constraint(equalToConstant: 48 * scale).isActive = true
                bar.addArrangedSubview(now)
                nowButton = now
            }
        }
        errorLabel.textColor = .systemRed
        errorLabel.font = .systemFont(ofSize: 11 * scale)
        errorLabel.maximumNumberOfLines = 2
        errorLabel.isHidden = true
        stack.addArrangedSubview(errorLabel)
        errorLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        resize()
    }

    private func buildText() {
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = column.cellKind.multiline
        scroll.drawsBackground = true
        textView.frame = NSRect(x: 0, y: 0, width: 260, height: 25 * scale)
        textView.autoresizingMask = [.width]
        textView.font = Theme.nativeCodeFont(scale: scale)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.textContainerInset = NSSize(width: 2, height: 3 * scale)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = !column.cellKind.multiline
        textView.textContainer?.widthTracksTextView = column.cellKind.multiline
        textView.textContainer?.containerSize = NSSize(width: column.cellKind.multiline ? 260 : 100_000, height: 100_000)
        textView.delegate = self
        textView.multiline = column.cellKind.multiline
        if case .text(let text) = original { textView.string = text }
        textView.setAccessibilityLabel("Valor de " + column.name)
        textView.toolTip = "Enter: confirmar · ⌘Enter: salto de línea en texto · Esc: cancelar"
        textView.confirm = { [weak self] in self?.confirmEditing() }
        textView.cancel = { [weak self] in self?.cancelEditing() }
        textView.advance = { [weak self] backwards in
            guard let self, self.confirmValue() else { return }
            self.onAdvance?(backwards)
        }
        textView.lostFocus = { [weak self] in self?.finishOnBlur() }
        scroll.documentView = textView
        bar.addArrangedSubview(scroll)
        scroll.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let height = scroll.heightAnchor.constraint(equalToConstant: 25 * scale)
        height.isActive = true
        inputHeight = height
    }

    private func buildChoices(_ values: [String]) {
        choices.target = self
        choices.action = #selector(choiceChanged)
        choices.font = Theme.nativeCodeFont(scale: scale)
        choiceValues = values.map { .text($0) }
        for value in values { choices.addItem(withTitle: value.isEmpty ? "(texto vacío)" : value) }
        if let index = choiceValues.firstIndex(where: { $0 == original }) { choices.selectItem(at: index)
        selectedChoice = original }
        else {
            choices.insertItem(withTitle: "Elegí un valor…", at: 0)
            choiceValues.insert(nil, at: 0)
            choices.selectItem(at: 0)
        }
        choices.setAccessibilityLabel("Valores permitidos de " + column.name)
        choices.toolTip = "Valores ENUM definidos en el esquema"
        bar.addArrangedSubview(choices)
        choices.widthAnchor.constraint(equalTo: bar.widthAnchor).isActive = true
    }

    var calendarContent: NSView {
        if let calendarRoot { return calendarRoot }
        guard case .temporal(let kind, _) = column.cellKind else { return NSView() }
        picker.datePickerStyle = kind == .time || kind == .year ? .textFieldAndStepper : .clockAndCalendar
        picker.datePickerElements = kind == .time ? [.hourMinuteSecond]
            : kind == .date || kind == .year ? [.yearMonthDay] : [.yearMonthDay, .hourMinuteSecond]
        picker.timeZone = TimeZone(secondsFromGMT: 0)
        picker.calendar = Calendar(identifier: .gregorian)
        picker.locale = Locale(identifier: "en_US_POSIX")
        picker.target = self
        picker.action = #selector(datePicked)
        let base = textView.string.split(separator: ".").first.map(String.init) ?? ""
        picker.dateValue = SQLCellInput.formatter(kind).date(from: base) ?? Date()
        let size = picker.fittingSize
        let root = NSView(frame: NSRect(x: 0, y: 0, width: max(240, size.width + 24), height: size.height + 64))
        picker.frame = NSRect(x: 12, y: 48, width: size.width, height: size.height)
        root.addSubview(picker)
        let done = NSButton(title: "Listo", target: self, action: #selector(closeCalendar))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        done.keyEquivalentModifierMask = []
        done.frame = NSRect(x: root.bounds.width - 92, y: 10, width: 80, height: 28)
        root.addSubview(done)
        calendarRoot = root
        return root
    }

    func show(relativeTo rect: NSRect, of parent: NSView) {
        let root = view
        root.frame = parent.bounds
        root.autoresizingMask = [.width, .height]
        parent.addSubview(root)
        Self.active = self
        if case .enumeration = column.cellKind {
            root.window?.makeFirstResponder(choices)
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.finished else { return }
                self.choices.performClick(nil)
            }
        } else {
            root.layoutSubtreeIfNeeded()
            root.window?.makeFirstResponder(textView)
            textView.setSelectedRange(NSRange(location: 0, length: textView.string.utf16.count))
        }
        resize()
    }
    @objc private func showCalendar() {
        guard !loadingNow, !finished else { return }
        let controller = NSViewController()
        controller.view = calendarContent
        if case .temporal(let kind, _) = column.cellKind {
            let base = textView.string.split(separator: ".").first.map(String.init) ?? ""
            if let date = SQLCellInput.formatter(kind).date(from: base) { picker.dateValue = date }
        }
        let popover = NSPopover()
        popover.animates = false
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = controller
        self.popover = popover
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
    }
    @objc private func closeCalendar() { popover?.close()
    view.window?.makeFirstResponder(textView) }

    func commandEnter() {
        if column.cellKind.multiline { textView.commandEnter() } else { NSSound.beep() }
    }
    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        guard let replacementString, NSMaxRange(affectedCharRange) <= textView.string.utf16.count else { return false }
        let value = (textView.string as NSString).replacingCharacters(in: affectedCharRange, with: replacementString)
        guard SQLCellInput.allows(value, kind: column.cellKind) else {
            showError("Este campo admite valores de tipo " + column.type + ".")
            return false
        }
        return true
    }
    func textDidChange(_ notification: Notification) { changed = true
    errorLabel.isHidden = true
    resize() }

    @objc func confirmEditing() { _ = confirmValue() }
    @discardableResult func confirmValue(close: Bool = true) -> Bool {
        guard !finished else { return true }
        guard !loadingNow else { return false }
        do {
            let value: SQLCellValue
            if case .enumeration = column.cellKind { value = selectedChoice ?? original }
            else if !changed { value = original }
            else { value = .text(try SQLCellInput.validate(textView.string, column: column)) }
            finish(value)
            return true
        } catch { showError(error.localizedDescription)
        return false }
    }
    override func cancelOperation(_ sender: Any?) { cancelEditing() }
    @objc func cancelEditing() { finish(nil) }
    @objc private func choiceChanged() {
        guard choiceValues.indices.contains(choices.indexOfSelectedItem), let value = choiceValues[choices.indexOfSelectedItem] else {
            return
        }
        selectedChoice = value
        finish(value)
    }
    @objc private func datePicked() {
        guard case .temporal(let kind, let precision) = column.cellKind else { return }
        var text = SQLCellInput.formatter(kind).string(from: picker.dateValue)
        if ![.date, .year].contains(kind), precision > 0 {
            text += "." + String(repeating: "0", count: min(6, precision))
        }
        textView.string = text
        changed = true
        errorLabel.isHidden = true
        resize()
    }
    @objc func useNow() {
        guard !loadingNow, !finished, case .temporal = column.cellKind else { return }
        guard let serverNow else { showError("No se pudo acceder a la sesión MySQL.")
        return }
        loadingNow = true
        nowButton?.isEnabled = false
        nowButton?.title = "…"
        textView.isEditable = false
        clockTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.loadingNow = false
                self.nowButton?.isEnabled = true
                self.nowButton?.title = "Ahora"
                self.textView.isEditable = true
                self.clockTask = nil
            }
            do {
                let value = try await serverNow(self.column)
                guard !self.finished, !Task.isCancelled else { return }
                self.textView.string = try SQLCellInput.validate(value, column: self.column)
                self.changed = true
                self.errorLabel.isHidden = true
                self.resize()
                self.view.window?.makeFirstResponder(self.textView)
            } catch {
                guard !self.finished, !Task.isCancelled else { return }
                self.showError(error.localizedDescription)
            }
        }
    }
    private func finish(_ value: SQLCellValue?) {
        guard !finished else { return }
        finished = true
        clockTask?.cancel()
        clockTask = nil
        popover?.close()
        view.removeFromSuperview()
        if Self.active === self { Self.active = nil }
        onFinish?(value)
    }
    private func finishOnBlur() {
        guard isEditing, !loadingNow, popover?.isShown != true,
              let responder = view.window?.firstResponder as? NSView, !responder.isDescendant(of: view) else { return }
        if !confirmValue() { view.window?.makeFirstResponder(textView) }
    }
    private func showError(_ message: String) { errorLabel.stringValue = message
    errorLabel.isHidden = false
    view.toolTip = message
    resize() }
    private func resize() {
        let lineHeight = (textView.font?.ascender ?? 14) - (textView.font?.descender ?? -3) + 6 * scale
        var height = 25 * scale
        if column.cellKind.multiline {
            if let container = textView.textContainer, let layout = textView.layoutManager {
                layout.ensureLayout(for: container)
                height = min(200 * scale, max(height, layout.usedRect(for: container).height + 6 * scale))
            } else { height = max(height, CGFloat(textView.string.filter { $0 == "\n" }.count + 1) * lineHeight) }
        }
        inputHeight?.constant = height
        desiredHeight = max(27 * scale, height + 2 + (errorLabel.isHidden ? 0 : 36 * scale))
        preferredContentSize = NSSize(width: max(90, view.bounds.width), height: desiredHeight)
        onResize?()
    }
    func popoverDidClose(_ notification: Notification) {
        popover = nil
        if !finished { view.window?.makeFirstResponder(textView) }
    }
}
