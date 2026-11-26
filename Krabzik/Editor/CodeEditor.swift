import AppKit
import SwiftUI

@MainActor enum EditorPalette {
    static var background: NSColor { Theme.palette.background }
    static func background(for theme: AppTheme) -> NSColor { theme.palette.background }
    static var text: NSColor { Theme.palette.text }
    static var muted: NSColor { Theme.palette.muted }
    static var blue: NSColor { Theme.palette.identifier }
    static var purple: NSColor { Theme.palette.keyword }
    static var green: NSColor { Theme.palette.string }
    static var orange: NSColor { Theme.palette.number }
}

struct CodeEditor: NSViewRepresentable {
    let document: EditorDocument
    let theme: AppTheme
    let uiScale: Double
    let wrapsLines: Bool
    var readOnly = false
    var options = EditorOptions()
    var typography = CodeTypography()
    var canExecuteSelection = false
    var executeSelection: (() -> Void)?
    var navigationNoBackslashEscapes = false
    var openTableDefinition: ((Int) -> Void)?
    var completion: ((String, Int) -> [String])?

    func makeNSView(context: Context) -> EditorSurface {
        if let existing = document.editorStorage as? EditorSurface { return existing }
        let surface = EditorSurface(document: document)
        document.editorStorage = surface
        return surface
    }

    func updateNSView(_ view: EditorSurface, context: Context) {
        view.selectionActions.execute = executeSelection
        view.selectionActions.canExecute = canExecuteSelection
        view.selectionActions.readOnly = readOnly
        view.selectionActions.schedule()
        view.textView.navigationNoBackslashEscapes = navigationNoBackslashEscapes
        view.textView.openTableDefinition = document.language == "SQL" ? openTableDefinition : nil
        view.textView.isEditable = !readOnly
        view.completion = document.language == "SQL" ? completion : nil
        view.textView.sqlCompletionEnabled = view.completion != nil
        view.applyTheme(theme)
        view.applyZoom(uiScale)
        view.applyWrapLines(wrapsLines)
        _ = options
        view.textView.needsDisplay = true
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: EditorSurface, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 700, height: proposal.height ?? 400)
    }
}

enum SQLValuePillAction: CaseIterable { case copyReference, detail, copyValues }

private final class SQLValuePillButton: NSButton {
    var value: SQLSetValue?
    var kind = SQLValuePillAction.detail
    var pillRect: NSRect = .zero
    var iconSize: CGFloat = 10
    private var feedback: DispatchWorkItem?
    override var acceptsFirstResponder: Bool { false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    func refreshIcon() {
        guard kind != .detail else { image = nil
        return }
        image = NSImage(systemSymbolName: feedback == nil ? "doc.on.doc" : "checkmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: iconSize, weight: .regular))
        contentTintColor = feedback == nil ? .secondaryLabelColor : .systemGreen
    }
    func cancelFeedback() { feedback?.cancel()
    feedback = nil }
    func showCopied() {
        cancelFeedback()
        let work = DispatchWorkItem { [weak self] in
            self?.feedback = nil
            self?.refreshIcon()
        }
        feedback = work
        refreshIcon()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }
}

struct SQLValuePillHit {
    let rect: NSRect
    let value: SQLSetValue
    let copyWidth: CGFloat
    func frame(for action: SQLValuePillAction) -> NSRect {
        switch action {
        case .copyReference: NSRect(x: rect.minX, y: rect.minY, width: copyWidth, height: rect.height)
        case .detail: NSRect(x: rect.minX + copyWidth, y: rect.minY,
                             width: rect.width - copyWidth * 2, height: rect.height)
        case .copyValues: NSRect(x: rect.maxX - copyWidth, y: rect.minY, width: copyWidth, height: rect.height)
        }
    }
}

final class CodeTextView: NSTextView, NSPopoverDelegate {
    var navigationNoBackslashEscapes = false
    var openTableDefinition: ((Int) -> Void)?
    weak var editorSurface: EditorSurface?
    private var variableTooltips: [NSView.ToolTipTag: String] = [:]
    private(set) var valuePills: [SQLValuePillHit] = []
    private var valuePillButtons: [SQLValuePillButton] = []
    private(set) var valueDetailPopover: NSPopover?
    private var valueDetailCard: SQLValueDetailCard?
    var writeValueClipboard: (String) -> Void = { text in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @discardableResult
    func performValuePillAction(_ action: SQLValuePillAction, value: SQLSetValue, rect: NSRect) -> Bool {
        if action == .detail { openValueDetails(value, relativeTo: rect)
        return false }
        guard let text = action == .copyReference ? value.clipboardReference : value.clipboardValues else { return false }
        writeValueClipboard(text)
        return true
    }

    override func accessibilityChildren() -> [Any]? {
        var children = super.accessibilityChildren() ?? []
        for button in valuePillButtons where !children.contains(where: { ($0 as? NSView) === button }) {
            children.append(button)
        }
        return children
    }

    private func synchronizeValuePillButtons() {
        let count = valuePills.count * 3
        while valuePillButtons.count > count {
            let button = valuePillButtons.removeLast()
            button.cancelFeedback()
            button.removeFromSuperview()
        }
        while valuePillButtons.count < count {
            let button = SQLValuePillButton()
            // El nombre y el valor ya los dibuja el editor. Estos controles nunca dibujan títulos.
            button.title = ""
            button.alternateTitle = ""
            button.imagePosition = .imageOnly
            button.focusRingType = .none
            button.setAccessibilityElement(true)
            button.setAccessibilityRole(.button)
            button.isBordered = false
            button.target = self
            button.action = #selector(pressValuePill(_:))
            addSubview(button)
            valuePillButtons.append(button)
        }
        for (index, pill) in valuePills.enumerated() {
            for (offset, action) in SQLValuePillAction.allCases.enumerated() {
                let button = valuePillButtons[index * 3 + offset]
                if button.value?.name != pill.value.name || button.value?.value != pill.value.value
                    || button.value?.reference != pill.value.reference
                    || button.value?.listSnapshot?.capturedAt != pill.value.listSnapshot?.capturedAt { button.cancelFeedback() }
                let frame = pill.frame(for: action)
                if button.frame != frame { button.frame = frame }
                button.pillRect = pill.rect
                button.value = pill.value
                button.kind = action
                button.iconSize = pill.copyWidth / 2
                let title: String
                switch action {
                case .copyReference:
                    button.isEnabled = pill.value.clipboardReference != nil
                    title = "Copiar referencia " + (pill.value.clipboardReference ?? pill.value.name)
                case .detail:
                    button.isEnabled = true
                    title = "Ver valores de " + pill.value.name + ": " + pill.value.value
                case .copyValues:
                    button.isEnabled = !pill.value.isList || pill.value.listSnapshot?.values.isEmpty == false
                    title = "Copiar valores de " + pill.value.name
                }
                button.setAccessibilityLabel(title)
                button.toolTip = title
                button.refreshIcon()
            }
        }
    }

    @objc private func pressValuePill(_ sender: SQLValuePillButton) {
        guard let value = sender.value else { return }
        if performValuePillAction(sender.kind, value: value, rect: sender.pillRect) { sender.showCopied() }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        for pill in valuePills {
            let rect = NSIntersectionRect(pill.rect, visibleRect)
            if !rect.isEmpty { addCursorRect(rect, cursor: .pointingHand) }
        }
    }

    func openValueDetails(_ value: SQLSetValue, relativeTo rect: NSRect) {
        guard window != nil else { return }
        dismissValueDetails()
        editorSurface?.selectionActions.hide()
        let card = SQLValueDetailCard(value: value)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.appearance = effectiveAppearance
        popover.delegate = self
        popover.contentViewController = card
        popover.contentSize = card.preferredContentSize
        card.close = { [weak self] in
            guard let self else { return }
            self.dismissValueDetails()
            self.window?.makeFirstResponder(self)
        }
        valueDetailCard = card
        valueDetailPopover = popover
        popover.show(relativeTo: rect, of: self, preferredEdge: .maxY)
    }

    func dismissValueDetails() {
        valueDetailCard?.invalidate()
        valueDetailPopover?.close()
        valueDetailPopover = nil
        valueDetailCard = nil
    }

    func popoverDidClose(_ notification: Notification) {
        guard notification.object as? NSPopover === valueDetailPopover else { return }
        valueDetailCard?.invalidate()
        valueDetailCard = nil
        valueDetailPopover = nil
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        drawAssistance(in: rect)
        guard let search = editorSurface?.document?.search, search.visible, !search.matches.isEmpty,
              let layout = textLayoutManager, let content = layout.textContentManager,
              let viewport = layout.textViewportLayoutController.viewportRange else { return }
        let start = content.offset(from: content.documentRange.location, to: viewport.location)
        let end = content.offset(from: content.documentRange.location, to: viewport.endLocation)
        var low = 0, high = search.matches.count
        while low < high {
            let middle = (low + high) / 2
            if NSMaxRange(search.matches[middle].range) < start { low = middle + 1 } else { high = middle }
        }
        for index in low..<search.matches.count {
            let match = search.matches[index].range
            if match.location > end { break }
            guard NSMaxRange(match) <= (textStorage?.length ?? 0),
                  let location = content.location(content.documentRange.location, offsetBy: match.location),
                  let endLocation = content.location(location, offsetBy: match.length),
                  let range = NSTextRange(location: location, end: endLocation) else { continue }
            let active = index == search.currentIndex
            layout.enumerateTextSegments(in: range, type: .standard, options: []) { _, frame, _, _ in
                let highlight = frame.offsetBy(dx: self.textContainerOrigin.x, dy: self.textContainerOrigin.y)
                let shape = NSBezierPath(roundedRect: NSRect(x: highlight.minX, y: highlight.minY,
                                                             width: max(2, highlight.width), height: highlight.height),
                                         xRadius: 3, yRadius: 3)
                NSColor.systemOrange.withAlphaComponent(active ? 0.3 : 0.13).setFill()
                shape.fill()
                if active {
                    NSColor.systemOrange.withAlphaComponent(0.8).setStroke()
                    shape.lineWidth = 1
                    shape.stroke()
                }
                return true
            }
        }
    }

    override func performFindPanelAction(_ sender: Any?) {
        guard let document = editorSurface?.document else { return }
        let tag = (sender as? NSMenuItem)?.tag
        if tag == NSTextFinder.Action.nextMatch.rawValue { document.search.navigate() }
        else if tag == NSTextFinder.Action.previousMatch.rawValue { document.search.navigate(backwards: true) }
        else { document.search.show(in: document, replace: tag == NSTextFinder.Action.showReplaceInterface.rawValue) }
    }

    override func sizeToFit() {
        super.sizeToFit()
        if textContainer?.widthTracksTextView == false, editorSurface?.document?.setNotes.isEmpty == false {
            setFrameSize(NSSize(width: frame.width + 600 * (editorSurface?.lineNumberScale ?? 1), height: frame.height))
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        removeAllToolTips()
        variableTooltips.removeAll()
        let previousRects = valuePills.map(\.rect)
        valuePills.removeAll(keepingCapacity: true)
        defer {
            synchronizeValuePillButtons()
            if previousRects != valuePills.map(\.rect) { window?.invalidateCursorRects(for: self) }
        }
        guard let surface = editorSurface, let notes = surface.document?.setNotes, !notes.isEmpty,
              let layout = textLayoutManager, let content = layout.textContentManager,
              let viewport = layout.textViewportLayoutController.viewportRange else { return }
        let scale = surface.lineNumberScale
        layout.enumerateTextLayoutFragments(from: viewport.location, options: []) { fragment in
            let frame = fragment.layoutFragmentFrame
            if frame.minY > self.visibleRect.maxY { return false }
            let offset = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
            for line in fragment.textLineFragments {
                let lineNumber = surface.lines.line(at: offset + line.characterRange.location)
                guard let note = notes[lineNumber + 1] else { continue }
                let end = lineNumber + 1 < surface.lines.count
                    ? surface.lines.start(of: lineNumber + 1) - 1 : (self.textStorage?.length ?? 0)
                guard offset + NSMaxRange(line.characterRange) >= end else { continue }
                var x = frame.minX + line.typographicBounds.maxX + self.textContainerInset.width + 16 * scale
                let y = frame.minY + line.typographicBounds.minY + self.textContainerInset.height + 2 * scale
                for value in note.values {
                    let available = self.visibleRect.maxX - x - 8 * scale
                    guard available > 45 * scale else { break }
                    let width = self.drawVariablePill(value, error: note.error, at: NSPoint(x: x, y: y),
                                                      available: available, scale: scale)
                    x += width + 7 * scale
                }
            }
            return true
        }
    }

    private func drawVariablePill(_ value: SQLSetValue, error: String?, at origin: NSPoint,
                                  available: CGFloat, scale: CGFloat) -> CGFloat {
        let size = (font?.pointSize ?? 15 * scale) * 0.88
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: Theme.settings.codeTypography.nativeFont(size: size),
            .foregroundColor: EditorPalette.muted, .paragraphStyle: paragraph
        ]
        let valueAttributes: [NSAttributedString.Key: Any] = [
            .font: Theme.settings.codeTypography.nativeFont(size: size, forceBold: true),
            .foregroundColor: error == nil ? (value.isList ? NSColor.systemBlue : EditorPalette.green) : NSColor.systemOrange,
            .paragraphStyle: paragraph
        ]
        let label = value.name as NSString
        let text = value.value.replacingOccurrences(of: "\n", with: "↵").replacingOccurrences(of: "\r", with: "") as NSString
        let padding = 8 * scale
        let copyWidth = 20 * scale
        let textBudget = available - copyWidth * 2 - padding * 4 - 1
        guard textBudget > 24 * scale else { return 0 }
        let labelWidth = min(label.size(withAttributes: labelAttributes).width, min(180 * scale, textBudget * 0.65))
        let valueWidth = min(text.size(withAttributes: valueAttributes).width, min(260 * scale, textBudget - labelWidth))
        let width = labelWidth + valueWidth + padding * 4 + copyWidth * 2 + 1
        let height = max(19 * scale, size + 6 * scale)
        let rect = NSRect(origin: origin, size: NSSize(width: width, height: height))
        let shape = NSBezierPath(roundedRect: rect, xRadius: height / 2, yRadius: height / 2)
        let divider = rect.minX + copyWidth + labelWidth + padding * 2
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        (value.isList ? NSColor.systemBlue : NSColor.labelColor).withAlphaComponent(0.06).setFill()
        rect.fill()
        NSColor.labelColor.withAlphaComponent(0.045).setFill()
        NSRect(x: divider, y: rect.minY, width: rect.maxX - divider, height: height).fill()
        NSColor.separatorColor.setFill()
        NSRect(x: divider, y: rect.minY + 3 * scale, width: 0.7, height: height - 6 * scale).fill()
        let baselineInset = (height - label.size(withAttributes: labelAttributes).height) / 2
        label.draw(in: NSRect(x: rect.minX + copyWidth + padding, y: rect.minY + baselineInset,
                              width: labelWidth, height: height), withAttributes: labelAttributes)
        text.draw(in: NSRect(x: divider + padding, y: rect.minY + baselineInset,
                             width: max(0, rect.maxX - copyWidth - divider - padding * 2), height: height), withAttributes: valueAttributes)
        NSGraphicsContext.restoreGraphicsState()
        NSColor.labelColor.withAlphaComponent(0.18).setStroke()
        shape.lineWidth = 0.7
        shape.stroke()
        let tag = addToolTip(rect, owner: self, userData: nil)
        variableTooltips[tag] = error ?? ((value.detail ?? (value.name + " = " + value.value)) + "\nClic para ver los valores")
        if error == nil { valuePills.append(SQLValuePillHit(rect: rect, value: value, copyWidth: copyWidth)) }
        return width
    }

    @objc func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint,
                    userData: UnsafeMutableRawPointer?) -> String {
        variableTooltips[tag] ?? ""
    }

    private let editHistory = UndoManager()
    override var undoManager: UndoManager? { editHistory }

    var formattingSQL = false
    var sqlCompletionEnabled = false
    var requestCompletion: (() -> Void)?
    var completionKey: ((NSEvent) -> Bool)?
    override func complete(_ sender: Any?) {
        if sqlCompletionEnabled { requestCompletion?() } else { super.complete(sender) }
    }
    override var rangeForUserCompletion: NSRange {
        guard sqlCompletionEnabled, selectedRange().length == 0 else { return super.rangeForUserCompletion }
        let position = selectedRange().location
        let prefix = (string as NSString).substring(to: position)
        let word = String(prefix.reversed().prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "$" }.reversed())
        var length = word.utf16.count
        if prefix.range(of: #"\{\{[A-Za-z0-9_]*$"#, options: .regularExpression) != nil,
           position + 2 <= string.utf16.count,
           (string as NSString).substring(with: NSRange(location: position, length: 2)) == "}}" { length += 2 }
        return NSRange(location: position - word.utf16.count, length: length)
    }

    override func mouseDown(with event: NSEvent) {
        editorSurface?.selectionActions.hide()
        let point = convert(event.locationInWindow, from: nil)
        if let pill = valuePills.last(where: { $0.rect.contains(point) }) {
            let action = SQLValuePillAction.allCases.first { pill.frame(for: $0).contains(point) } ?? .detail
            performValuePillAction(action, value: pill.value, rect: pill.rect)
            return
        }
        if event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
           let openTableDefinition, let layoutManager, let textContainer {
            let location = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
            let glyph = layoutManager.glyphIndex(for: location, in: textContainer)
            if glyph < layoutManager.numberOfGlyphs,
               layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
                .insetBy(dx: -2, dy: 0).contains(location) {
                let position = layoutManager.characterIndexForGlyph(at: glyph)
                if SQLTableReference.at(position, in: string,
                                        noBackslashEscapes: navigationNoBackslashEscapes) != nil {
                    openTableDefinition(position)
                    return
                }
            }
        }
        dismissValueDetails()
        super.mouseDown(with: event)
        editorSurface?.selectionActions.schedule()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, editorSurface?.selectionActions.visible == true {
            editorSurface?.selectionActions.hide()
            return
        }
        if completionKey?(event) == true { return }
        if event.keyCode == 53, editorSurface?.document?.search.visible == true {
            editorSurface?.document?.search.hide()
            return
        }
        if event.modifierFlags.contains(.control), event.keyCode == 49 { complete(nil)
        return }
        super.keyDown(with: event)
    }

    override func insertTab(_ sender: Any?) {
        insertText(String(repeating: " ", count: Theme.settings.editorOptions.indentWidth), replacementRange: selectedRange())
    }

    override func insertBacktab(_ sender: Any?) {
        let selection = selectedRange()
        let source = string as NSString
        let start = source.lineRange(for: NSRange(location: selection.location, length: 0)).location
        let lastPosition = selection.length > 0 ? NSMaxRange(selection) - 1 : selection.location
        let end = NSMaxRange(source.lineRange(for: NSRange(location: lastPosition, length: 0)))
        let original = source.substring(with: NSRange(location: start, length: end - start)) as NSString
        let result = NSMutableString(string: original)
        var removals: [(location: Int, length: Int)] = []
        var offset = 0
        while offset < original.length {
            let line = original.lineRange(for: NSRange(location: offset, length: 0))
            var count = 0
            if original.character(at: offset) == 9 {
                count = 1
            } else {
                while count < Theme.settings.editorOptions.indentWidth, offset + count < NSMaxRange(line),
                      original.character(at: offset + count) == 32 {
                    count += 1
                }
            }
            if count > 0 { removals.append((start + offset, count)) }
            offset = NSMaxRange(line)
        }
        guard !removals.isEmpty else { return }
        for removal in removals.reversed() {
            result.deleteCharacters(in: NSRange(location: removal.location - start, length: removal.length))
        }
        func adjusted(_ position: Int) -> Int {
            position - removals.reduce(0) { $0 + max(0, min($1.length, position - $1.location)) }
        }
        let newStart = adjusted(selection.location)
        let newEnd = adjusted(NSMaxRange(selection))
        insertText(result as String, replacementRange: NSRange(location: start, length: end - start))
        setSelectedRange(NSRange(location: newStart, length: newEnd - newStart))
    }

    override func deleteWordBackward(_ sender: Any?) {
        guard sqlCompletionEnabled, selectedRange().length == 0 else {
            super.deleteWordBackward(sender)
            return
        }
        let position = selectedRange().location
        guard position > 0 else { return }
        let text = string as NSString
        let lineStart = text.lineRange(for: NSRange(location: position, length: 0)).location
        let prefix = text.substring(with: NSRange(location: lineStart, length: position - lineStart))
        if prefix.trimmingCharacters(in: .whitespaces).isEmpty, lineStart > 0 {
            let previous = text.lineRange(for: NSRange(location: lineStart - 1, length: 0))
            var end = lineStart
            while end > previous.location {
                let char = text.character(at: end - 1)
                if char == 10 || char == 13 || char == 32 || char == 9 { end -= 1 } else { break }
            }
            insertText(" ", replacementRange: NSRange(location: end, length: position - end))
        } else if position > lineStart {
            insertText("", replacementRange: NSRange(location: lineStart, length: position - lineStart))
        }
    }

    override func insertNewline(_ sender: Any?) {
        let text = string as NSString
        let position = selectedRange().location
        let range = text.lineRange(for: NSRange(location: position, length: 0))
        let previous = text.substring(with: NSRange(location: range.location, length: max(0, position - range.location)))
        let indent = String(previous.prefix { $0 == " " || $0 == "\t" })
        let opening = previous.trimmingCharacters(in: .whitespaces).last
        let paired = opening.flatMap { ["(": ")", "[": "]", "{": "}"][$0] }
        let extra = paired == nil ? "" : String(repeating: " ", count: Theme.settings.editorOptions.indentWidth)
        if let paired, position < text.length, text.substring(with: NSRange(location: position, length: 1)) == String(paired) {
            insertText("\n" + indent + extra + "\n" + indent, replacementRange: selectedRange())
            setSelectedRange(NSRange(location: position + 1 + indent.utf16.count + extra.utf16.count, length: 0))
        } else {
            insertText("\n" + indent + extra, replacementRange: selectedRange())
        }
    }
}

/// Quita el observador en su propio `deinit`, que puede correr en cualquier hilo.
/// `@unchecked Sendable` es seguro acá porque lo único que se hace con el token es
/// pasarlo a `removeObserver`, que NotificationCenter admite desde cualquier hilo.
private final class ObserverToken: @unchecked Sendable {
    private let token: any NSObjectProtocol
    init(_ token: any NSObjectProtocol) { self.token = token }
    deinit { NotificationCenter.default.removeObserver(token) }
}

@MainActor final class EditorSurface: NSView, NSTextViewDelegate, NSTextStorageDelegate {
    let scrollView = NSScrollView()
    let textView = CodeTextView(usingTextLayoutManager: true)
    weak var document: EditorDocument?
    var completion: ((String, Int) -> [String])?
    var lines: LineIndex
    let selectionActions = SQLSelectionActions()
    private let suggestions = SQLCompletionList()
    private var completionWork: DispatchWorkItem?
    private var highlighter: DispatchWorkItem?
    private var syntax: SyntaxHighlighter
    private var highlightTask: Task<Void, Never>?
    private var scrollObserver: ObserverToken?
    private var gutter: LineRuler!
    private var paragraph: NSParagraphStyle
    private(set) var structure: EditorStructure?
    private var editRevision = 0
    private var highlightedRevision = -1
    private var highlightedRange = NSRange(location: NSNotFound, length: 0)
    private var appliedTheme: AppTheme?
    private var appliedZoom = 1.0
    private var appliedWrapLines = true
    var lineNumberScale: CGFloat { CGFloat(appliedZoom) }

    init(document: EditorDocument) {
        self.document = document
        self.syntax = SyntaxHighlighter(text: document.text, url: document.url)
        self.lines = LineIndex(document.text)
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = 23
        style.maximumLineHeight = 23
        style.tabStops = []
        style.defaultTabInterval = ("    " as NSString).size(withAttributes: [.font: Theme.nativeCodeFont()]).width
        self.paragraph = style
        super.init(frame: .zero)
        wantsLayer = true
        clipsToBounds = true

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = EditorPalette.background
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor), scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor), scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        textView.editorSurface = self
        selectionActions.surface = self
        textView.frame = NSRect(x: 0, y: 0, width: 900, height: 0)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: 10_000_000, height: 10_000_000)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: 900, height: 10_000_000)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 12, height: 18)
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.usesFindBar = false
        textView.isIncrementalSearchingEnabled = false
        textView.font = Theme.nativeCodeFont()
        textView.textColor = EditorPalette.text
        textView.backgroundColor = EditorPalette.background
        textView.insertionPointColor = EditorPalette.text
        textView.defaultParagraphStyle = paragraph
        textView.typingAttributes = baseAttributes
        textView.string = document.text
        textView.textStorage?.setAttributes(baseAttributes, range: NSRange(location: 0, length: (document.text as NSString).length))
        textView.delegate = self
        textView.textStorage?.delegate = self
        textView.requestCompletion = { [weak self] in
            guard let self, let completion = self.completion else { return }
            self.selectionActions.hide()
            let values = completion(self.textView.string, self.textView.selectedRange().location)
            QAProbe.action("editor.completion.show", ["count": QAField.count(values.count),
                                                      "first": QAField.text(values.first ?? "")])
            self.suggestions.show(values, in: self, textView: self.textView)
        }
        textView.completionKey = { [weak self] event in self?.suggestions.handle(event) ?? false }
        suggestions.accept = { [weak self] value in
            guard let self else { return }
            self.window?.makeFirstResponder(self.textView)
            let replaced = (self.textView.string as NSString).substring(with: self.textView.rangeForUserCompletion)
            self.textView.insertText(value, replacementRange: self.textView.rangeForUserCompletion)
            QAProbe.action("editor.completion.accept", ["value": QAField.text(value),
                                                        "replaced": QAField.text(replaced)])
            self.completionWork?.cancel()
        }
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.setAccessibilityLabel(document.url.lastPathComponent)
        scrollView.documentView = textView
        gutter = LineRuler(surface: self)
        scrollView.verticalRulerView = gutter
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollObserver = ObserverToken(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                                                                              object: scrollView.contentView,
                                                                              queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.gutter.needsDisplay = true
                    self?.scheduleHighlight()
                    self?.selectionActions.reposition()
                    self?.textView.dismissValueDetails()
                }
            })
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func applyTheme(_ theme: AppTheme) {
        guard appliedTheme != theme else { return }
        appliedTheme = theme
        let history = textView.undoManager
        history?.disableUndoRegistration()
        defer { history?.enableUndoRegistration() }
        appearance = NSAppearance(named: theme.isLight ? .aqua : .darkAqua)
        scrollView.backgroundColor = EditorPalette.background(for: theme)
        textView.backgroundColor = EditorPalette.background(for: theme)
        textView.textColor = theme.palette.text
        textView.insertionPointColor = theme.palette.text
        textView.selectedTextAttributes = [.backgroundColor: theme.palette.selection]
        highlightedRange = NSRange(location: NSNotFound, length: 0)
        highlightVisibleText()
        gutter.needsDisplay = true
    }

    func applyZoom(_ scale: Double) {
        let font = Theme.nativeCodeFont(scale: scale)
        guard appliedZoom != scale || textView.font != font else { return }
        textView.dismissValueDetails()
        appliedZoom = scale
        let history = textView.undoManager
        history?.disableUndoRegistration()
        defer { history?.enableUndoRegistration() }
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = 23 * CGFloat(scale)
        style.maximumLineHeight = 23 * CGFloat(scale)
        style.tabStops = []
        style.defaultTabInterval = ("    " as NSString).size(withAttributes: [.font: font]).width
        paragraph = style
        textView.font = font
        textView.defaultParagraphStyle = style
        textView.textContainerInset = NSSize(width: 12 * CGFloat(scale), height: 18 * CGFloat(scale))
        textView.typingAttributes = baseAttributes
        if let storage = textView.textStorage, storage.length > 0 {
            let range = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.addAttributes([.font: font, .paragraphStyle: style], range: range)
            storage.endEditing()
        }
        gutter.updateThickness()
        gutter.needsDisplay = true
        textView.needsLayout = true
    }

    func applyWrapLines(_ wraps: Bool) {
        guard appliedWrapLines != wraps else { return }
        textView.dismissValueDetails()
        appliedWrapLines = wraps
        scrollView.hasHorizontalScroller = !wraps
        textView.isHorizontallyResizable = !wraps
        textView.autoresizingMask = wraps ? [.width] : []
        textView.textContainer?.widthTracksTextView = wraps
        textView.textContainer?.containerSize = NSSize(width: wraps ? max(1, scrollView.contentSize.width) : 10_000_000,
                                                       height: 10_000_000)
        if wraps {
            textView.setFrameSize(NSSize(width: max(1, scrollView.contentSize.width), height: textView.frame.height))
        } else {
            textView.sizeToFit()
        }
        textView.needsLayout = true
        gutter.needsDisplay = true
    }

    func reloadFromDocument() {
        guard let document else { return }
        let selection = textView.selectedRange()
        syntax = SyntaxHighlighter(text: document.text, url: document.url)
        highlightTask?.cancel()
        textView.textStorage?.delegate = nil
        textView.string = document.text
        textView.textStorage?.delegate = self
        lines = LineIndex(document.text)
        gutter.updateThickness()
        textView.undoManager?.removeAllActions()
        textView.textStorage?.setAttributes(baseAttributes, range: NSRange(location: 0, length: (document.text as NSString).length))
        textView.setSelectedRange(NSRange(location: min(selection.location, (document.text as NSString).length), length: 0))
        editRevision += 1
        gutter.needsDisplay = true
        scheduleHighlight()
        updatePosition()
    }

    func refreshQueryMarkers() {
        textView.needsDisplay = true
        if !appliedWrapLines { textView.sizeToFit() }
        gutter.updateLoadingAnimation()
        gutter.needsDisplay = true
    }

    /// Expuesto para las pruebas: indica si el surface sigue observando el scroll.
    var isObservingScroll: Bool { scrollObserver != nil }

    /// Limpieza determinista, idempotente. La llama el documento al cerrarse.
    /// No se hace en `deinit` porque es `nonisolated` y no puede tocar estas propiedades.
    /// Si nadie la llama, `ObserverToken` quita el observador al liberarse y el resaltado
    /// pendiente no hace nada, porque captura `self` de forma débil.
    func teardown() {
        textView.dismissValueDetails()
        selectionActions.invalidate()
        gutter.stopLoadingAnimation()
        completionWork?.cancel()
        suggestions.hide()
        scrollObserver = nil
        highlighter?.cancel()
        highlighter = nil
        highlightTask?.cancel()
    }

    private var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: Theme.nativeCodeFont(scale: appliedZoom),
         .foregroundColor: EditorPalette.text, .paragraphStyle: paragraph]
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        selectionActions.hide()
        if window == nil { textView.dismissValueDetails() }
        if window != nil {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.document?.focusEditorOnOpen != false, self.document?.search.visible != true {
                    self.window?.makeFirstResponder(self.textView)
                }
                self.scheduleHighlight()
                self.selectionActions.schedule()
            }
        }
    }

    override func layout() {
        super.layout()
        selectionActions.reposition()
        textView.minSize.width = max(0, scrollView.contentSize.width)
        gutter.needsDisplay = true
        scheduleHighlight()
    }

    nonisolated func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                                 range editedRange: NSRange, changeInLength delta: Int) {
        // AppKit edits this text storage synchronously on the UI thread.
        guard editedMask.contains(.editedCharacters) else { return }
        let originalRange = NSRange(location: editedRange.location, length: editedRange.length - delta)
        let replacement = textStorage.mutableString.substring(with: editedRange)
        MainActor.assumeIsolated {
            syntax.replace(originalRange, with: replacement)
            lines.replace(originalRange, with: replacement)
            editRevision += 1
            structure = nil
            textView.needsDisplay = true
            document?.markTextStale()
            if document?.isDirty == false { document?.isDirty = true }
            gutter.updateThickness()
            gutter.needsDisplay = true
            scheduleHighlight()
        }
    }

    func textDidChange(_ notification: Notification) {
        textView.dismissValueDetails()
        selectionActions.hide()
        completionWork?.cancel()
        if completion != nil, !textView.hasMarkedText(), textView.selectedRange().length == 0 {
            let prefix = (textView.string as NSString).substring(to: textView.selectedRange().location)
            let token = prefix.reversed().prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            if prefix.hasSuffix(".") || token.count >= 2 {
                let work = DispatchWorkItem { [weak self] in self?.textView.complete(nil) }
                completionWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
            }
        }
        textView.typingAttributes = baseAttributes
        updatePosition()
    }

    func textView(_ textView: NSTextView, completions words: [String], forPartialWordRange charRange: NSRange,
                  indexOfSelectedItem index: UnsafeMutablePointer<Int>?) -> [String] {
        if completion != nil { index?.pointee = -1 }
        return completion?(textView.string, NSMaxRange(charRange)) ?? words
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        suggestions.hide()
        selectionActions.schedule()
        textView.needsDisplay = true
        updatePosition()
    }

    private func updatePosition() {
        document?.selectedRange = textView.selectedRange()
        let position = textView.selectedRange().location
        let line = lines.line(at: position)
        document?.line = line + 1
        document?.column = position - lines.start(of: line) + 1
    }

    private func scheduleHighlight() {
        highlighter?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.highlightVisibleText() }
        highlighter = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.075, execute: work)
    }

    private func highlightVisibleText() {
        guard let storage = textView.textStorage, let layout = textView.textLayoutManager,
              let content = layout.textContentManager, let viewport = layout.textViewportLayoutController.viewportRange else { return }
        let start = content.offset(from: content.documentRange.location, to: viewport.location)
        let end = content.offset(from: content.documentRange.location, to: viewport.endLocation)
        guard start >= 0, end >= start, end <= storage.length else { return }
        let range = NSRange(location: start, length: min(end - start, 60_000))
        guard range.length <= 60_000 else { return }
        guard highlightedRevision != editRevision || highlightedRange != range else { return }
        highlightedRevision = editRevision
        highlightedRange = range
        highlightTask?.cancel()
        let revision = editRevision
        let syntax = syntax
        highlightTask = Task { [weak self] in
            let spans = await syntax.highlights(in: range)
            let structure = await syntax.structure()
            guard !Task.isCancelled, let self, self.editRevision == revision else { return }
            self.structure = structure
            self.textView.needsDisplay = true
            // Syntax colors are presentation changes, never user edits. TextKit 2
            // otherwise puts these attribute edits on the undo stack (and clears redo).
            let history = self.textView.undoManager
            history?.disableUndoRegistration()
            defer { history?.enableUndoRegistration() }
            SyntaxHighlighter.apply(spans, to: storage, range: range)
        }
    }
}

@MainActor final class LineRuler: NSRulerView {
    weak var surface: EditorSurface?
    private var loadingTimer: Timer?
    private static let baseThickness: CGFloat = 76
    private static let statusLaneWidth: CGFloat = 22
    private static let numberToStatusGap: CGFloat = 8
    private static let lineHeight: CGFloat = 23
    private static let topInset: CGFloat = 18

    init(surface: EditorSurface) {
        self.surface = surface
        super.init(scrollView: surface.scrollView, orientation: .verticalRuler)
        updateThickness()
        clientView = surface.textView
        wantsLayer = true
        clipsToBounds = true
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let notifications = NSWorkspace.shared.notificationCenter
        notifications.removeObserver(self, name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        if window != nil {
            notifications.addObserver(self, selector: #selector(updateLoadingAnimation),
                                      name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        }
        updateLoadingAnimation()
    }

    @objc func updateLoadingAnimation() {
        let loading = surface?.document?.queryMarkers.values.contains { $0.status == .loading } == true
        guard window != nil, loading, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            stopLoadingAnimation()
            return
        }
        guard loadingTimer == nil else { return }
        let timer = Timer(timeInterval: 1 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.needsDisplay = true }
        }
        RunLoop.main.add(timer, forMode: .common)
        loadingTimer = timer
    }

    func stopLoadingAnimation() {
        loadingTimer?.invalidate()
        loadingTimer = nil
    }

    func updateThickness() {
        guard let surface else { return }
        let scale = surface.lineNumberScale
        let font = Theme.settings.codeTypography.nativeFont(size: 12 * scale)
        let digitWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
        let digits = CGFloat(String(max(surface.lines.count, 99)).count)
        let required = (8 + Self.statusLaneWidth + Self.numberToStatusGap + 12) * scale + digits * digitWidth
        ruleThickness = max(Self.baseThickness * scale, required)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        EditorPalette.background.setFill()
        bounds.fill()
        guard let surface else { return }
        let scale = surface.lineNumberScale
        let rowHeight = Self.lineHeight * scale
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Theme.settings.codeTypography.nativeFont(size: 12 * scale),
            .foregroundColor: EditorPalette.muted
        ]
        let numberRight = ruleThickness - (Self.statusLaneWidth + Self.numberToStatusGap) * scale
        func drawMarker(_ marker: SQLQueryMarker, at y: CGFloat) {
            let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) != .aqua
            let color: NSColor
            switch marker.status {
            case .loading:
                color = dark ? NSColor(srgbRed: 0.922, green: 0.651, blue: 0.4, alpha: 1)
                    : NSColor(srgbRed: 0.718, green: 0.353, blue: 0.141, alpha: 1)
            case .success:
                color = dark ? NSColor(srgbRed: 0.455, green: 0.835, blue: 0.608, alpha: 1)
                    : NSColor(srgbRed: 0.129, green: 0.514, blue: 0.298, alpha: 1)
            case .failure:
                color = dark ? NSColor(srgbRed: 0.933, green: 0.478, blue: 0.494, alpha: 1)
                    : NSColor(srgbRed: 0.769, green: 0.22, blue: 0.278, alpha: 1)
            }
            let size = 16 * scale
            let x = numberRight + (Self.numberToStatusGap + (Self.statusLaneWidth - 16) / 2) * scale
            let icon = NSRect(x: x, y: y + 1 * scale, width: size, height: size)
            let center = NSPoint(x: icon.midX, y: icon.midY)
            let radius = size * 23 / 64
            color.setStroke()
            if marker.status == .loading {
                let turn = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 :
                    CGFloat(Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.1) / 1.1 * 360)
                let arc = NSBezierPath()
                arc.appendArc(withCenter: center, radius: radius, startAngle: turn + 32, endAngle: turn + 292)
                arc.lineWidth = size * 4.5 / 64
                arc.lineCapStyle = .round
                arc.stroke()
                return
            }
            let ring = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius,
                                                   width: radius * 2, height: radius * 2))
            ring.lineWidth = size * 4 / 64
            ring.stroke()
            func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
                NSPoint(x: icon.minX + x * size / 64,
                        y: icon.minY + (isFlipped ? y : 64 - y) * size / 64)
            }
            let glyph = NSBezierPath()
            if marker.status == .success {
                glyph.move(to: point(20, 33))
                glyph.line(to: point(29, 41))
                glyph.line(to: point(45, 23))
            } else {
                glyph.move(to: point(23, 23))
                glyph.line(to: point(41, 41))
                glyph.move(to: point(41, 23))
                glyph.line(to: point(23, 41))
            }
            glyph.lineWidth = size * 5 / 64
            glyph.lineCapStyle = .round
            glyph.lineJoinStyle = .round
            glyph.stroke()
        }
        func drawNumber(_ number: Int, at y: CGFloat) {
            guard y + rowHeight >= bounds.minY, y <= bounds.maxY else { return }
            let label = "\(number)" as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: numberRight - size.width, y: y), withAttributes: attributes)
            if let marker = surface.document?.queryMarkers[number] { drawMarker(marker, at: y) }
        }

        for row in visibleLineLabels() { drawNumber(row.number, at: row.y) }
    }

    /// TextKit includes the final empty line inside the preceding layout fragment.
    /// Use individual line fragments so Enter never leaves a hole in the gutter.
    func visibleLineLabels() -> [(number: Int, y: CGFloat)] {
        guard let surface else { return [] }
        let visible = surface.scrollView.contentView.bounds
        let scale = surface.lineNumberScale
        let rowHeight = Self.lineHeight * scale
        var labels: [(number: Int, y: CGFloat)] = []
        var lastNumber = 0
        var nextY = (Self.topInset + 4) * scale - visible.minY
        if let layout = surface.textView.textLayoutManager,
           let content = layout.textContentManager,
           let viewport = layout.textViewportLayoutController.viewportRange {
            layout.enumerateTextLayoutFragments(from: viewport.location, options: []) { fragment in
                let frame = fragment.layoutFragmentFrame
                if frame.minY > visible.maxY { return false }
                let offset = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
                for line in fragment.textLineFragments {
                    let number = surface.lines.line(at: offset + line.characterRange.location) + 1
                    let y = frame.minY + line.typographicBounds.minY + surface.textView.textContainerInset.height
                        - visible.minY + 4 * scale
                    if number > lastNumber {
                        labels.append((number, y))
                        lastNumber = number
                    }
                    nextY = y + rowHeight
                }
                return true
            }
        }
        if lastNumber >= surface.lines.count - 1 {
            var number = lastNumber + 1
            while nextY <= bounds.maxY {
                labels.append((number, nextY))
                number += 1
                nextY += rowHeight
            }
        }
        return labels
    }
}
