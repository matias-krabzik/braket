import AppKit

private final class SQLSelectionButton: NSButton {
    override var acceptsFirstResponder: Bool { false }
}

/// Barra propiedad del editor: no roba el foco ni modifica el texto seleccionado al pulsar Play.
@MainActor final class SQLSelectionActions: NSObject {
    weak var surface: EditorSurface?
    var execute: (() -> Void)?
    var canExecute = false
    var readOnly = false
    let view = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 79, height: 34))
    let play: NSButton = SQLSelectionButton()
    let comment: NSButton = SQLSelectionButton()
    private var pending: DispatchWorkItem?
    private var resignObserver: (any NSObjectProtocol)?
    private var range = NSRange(location: 0, length: 0)
    private var revision = 0
    private var invalidated = false
    var visible: Bool { !view.isHidden }

    override init() {
        super.init()
        view.material = .popover
        view.blendingMode = .withinWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = 6
        view.layer?.borderWidth = 1
        view.layer?.borderColor = NSColor.separatorColor.cgColor
        view.isHidden = true
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 5),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -5),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -4)
        ])
        for button in [play, comment] {
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.setButtonType(.momentaryChange)
            button.target = self
            button.widthAnchor.constraint(equalToConstant: 30).isActive = true
            button.heightAnchor.constraint(equalToConstant: 26).isActive = true
        }
        play.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)
        play.contentTintColor = .systemGreen
        play.action = #selector(run)
        play.toolTip = "Ejecutar selección (⌘Enter)"
        play.setAccessibilityLabel("Ejecutar selección")
        stack.addArrangedSubview(play)
        let separator = NSBox()
        separator.boxType = .separator
        separator.widthAnchor.constraint(equalToConstant: 1).isActive = true
        separator.heightAnchor.constraint(equalToConstant: 16).isActive = true
        stack.addArrangedSubview(separator)
        comment.action = #selector(toggleComment)
        stack.addArrangedSubview(comment)
        view.setAccessibilityLabel("Acciones de la selección SQL")
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                                                                object: nil, queue: .main) { [weak self] notification in
            let windowID = notification.object.map { ObjectIdentifier($0 as AnyObject) }
            MainActor.assumeIsolated {
                if let window = self?.surface?.window, windowID == ObjectIdentifier(window) { self?.hide() }
            }
        }
    }

    func schedule() {
        hide()
        guard !invalidated else { return }
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }
    func hide() { pending?.cancel()
    pending = nil
    view.isHidden = true }
    func invalidate() {
        invalidated = true
        hide()
        execute = nil
        view.removeFromSuperview()
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
    }

    func refresh() {
        guard !invalidated, let surface, let document = surface.document, document.language == "SQL",
              !readOnly, document.search.visible == false, let window = surface.window, window.isKeyWindow,
              window.firstResponder === surface.textView, NSEvent.pressedMouseButtons & 1 == 0,
              !surface.textView.hasMarkedText(),
              let edit = SQLCommentToggle.edit(in: surface.textView.string, selection: surface.textView.selectedRange()) else {
            hide()
            return
        }
        range = surface.textView.selectedRange()
        revision = document.previewRevision
        play.isEnabled = canExecute && execute != nil
        play.contentTintColor = play.isEnabled ? .systemGreen : .disabledControlTextColor
        comment.isEnabled = surface.textView.isEditable
        let title = edit.uncommenting ? "Descomentar líneas seleccionadas" : "Comentar líneas seleccionadas"
        comment.toolTip = title
        comment.setAccessibilityLabel(title)
        comment.image = NSImage(systemSymbolName: edit.uncommenting ? "text.badge.minus" : "text.badge.plus",
                                accessibilityDescription: nil) ?? NSImage(systemSymbolName: "text.bubble", accessibilityDescription: nil)
        if view.superview == nil { surface.addSubview(view) }
        view.isHidden = false
        reposition()
    }

    func reposition() {
        guard visible, let surface, let window = surface.window, range.length > 0 else { return }
        let anchor = surface.textView.firstRect(forCharacterRange: NSRange(location: range.location, length: 1), actualRange: nil)
        let inText = surface.textView.convert(window.convertFromScreen(anchor), from: nil)
        guard surface.textView.visibleRect.intersects(inText), surface.bounds.width >= view.frame.width,
              surface.bounds.height >= view.frame.height else { hide()
        return }
        let local = surface.convert(window.convertFromScreen(anchor), from: nil)
        let left = surface.scrollView.contentView.frame.minX + 4
        let x = max(left, min(local.minX, surface.bounds.maxX - view.frame.width - 4))
        let below = local.minY - view.frame.height - 5
        let y = below >= 2 ? below : min(surface.bounds.maxY - view.frame.height - 2, local.maxY + 5)
        view.setFrameOrigin(NSPoint(x: x, y: max(2, y)))
    }

    private func validTarget() -> EditorSurface? {
        guard let surface, !readOnly, surface.document?.previewRevision == revision,
              surface.textView.selectedRange() == range, range.length > 0 else { hide()
        return nil }
        return surface
    }
    @objc func run() {
        guard canExecute, let surface = validTarget(), let execute else { return }
        surface.window?.makeFirstResponder(surface.textView)
        hide()
        execute()
    }
    @objc func toggleComment() {
        guard let surface = validTarget(), surface.textView.isEditable,
              let edit = SQLCommentToggle.edit(in: surface.textView.string, selection: range) else { return }
        let textView = surface.textView
        textView.breakUndoCoalescing()
        textView.insertText(edit.replacement, replacementRange: edit.range)
        textView.breakUndoCoalescing()
        textView.undoManager?.setActionName(edit.uncommenting ? "Descomentar SQL" : "Comentar SQL")
        textView.setSelectedRange(edit.selection)
        surface.window?.makeFirstResponder(textView)
        schedule()
    }
}
