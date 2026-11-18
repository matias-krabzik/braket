import AppKit
import SwiftUI

enum EditorPalette {
    @MainActor static var background: NSColor {
        background(for: Theme.settings.theme)
    }
    static func background(for theme: AppTheme) -> NSColor {
        if theme == .light { return NSColor(srgbRed: 0.99, green: 0.99, blue: 0.995, alpha: 1) }
        return theme == .graphite
            ? NSColor(srgbRed: 0.122, green: 0.125, blue: 0.137, alpha: 1)
            : NSColor(calibratedRed: 0.105, green: 0.116, blue: 0.137, alpha: 1)
    }
    static let text = adaptive(light: (0.16, 0.19, 0.24), dark: (0.89, 0.90, 0.92))
    static let muted = adaptive(light: (0.40, 0.44, 0.49), dark: (0.53, 0.55, 0.59))
    static let blue = adaptive(light: (0.12, 0.32, 0.65), dark: (0.49, 0.72, 0.97))
    static let purple = adaptive(light: (0.48, 0.22, 0.64), dark: (0.76, 0.61, 0.93))
    static let green = adaptive(light: (0.19, 0.40, 0.26), dark: (0.60, 0.77, 0.65))
    static let orange = adaptive(light: (0.57, 0.31, 0.12), dark: (0.87, 0.70, 0.52))

    private static func adaptive(light: (Double, Double, Double), dark: (Double, Double, Double)) -> NSColor {
        NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua ? light : dark
            return NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        }
    }
}

struct CodeEditor: NSViewRepresentable {
    let document: EditorDocument
    let theme: AppTheme
    let uiScale: Double
    let wrapsLines: Bool
    var completion: ((String, Int) -> [String])?

    func makeNSView(context: Context) -> EditorSurface {
        if let existing = document.editorStorage as? EditorSurface { return existing }
        let surface = EditorSurface(document: document)
        document.editorStorage = surface
        return surface
    }

    func updateNSView(_ view: EditorSurface, context: Context) {
        view.completion = document.language == "SQL" ? completion : nil
        view.textView.sqlCompletionEnabled = view.completion != nil
        view.applyTheme(theme)
        view.applyZoom(uiScale)
        view.applyWrapLines(wrapsLines)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: EditorSurface, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 700, height: proposal.height ?? 400)
    }
}

final class CodeTextView: NSTextView {
    private let editHistory = UndoManager()
    override var undoManager: UndoManager? { editHistory }

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
        return NSRange(location: position - word.utf16.count, length: word.utf16.count)
    }

    override func keyDown(with event: NSEvent) {
        if completionKey?(event) == true { return }
        if event.modifierFlags.contains(.control), event.keyCode == 49 { complete(nil)
        return }
        super.keyDown(with: event)
    }

    override func insertTab(_ sender: Any?) { insertText("    ", replacementRange: selectedRange()) }

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
                while count < 4, offset + count < NSMaxRange(line), original.character(at: offset + count) == 32 {
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
        let extra = previous.trimmingCharacters(in: .whitespaces).hasSuffix("{") ? "    " : ""
        insertText("\n" + indent + extra, replacementRange: selectedRange())
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
    private let suggestions = SQLCompletionList()
    private var completionWork: DispatchWorkItem?
    private var highlighter: DispatchWorkItem?
    private var syntax: SyntaxHighlighter
    private var highlightTask: Task<Void, Never>?
    private var scrollObserver: ObserverToken?
    private var gutter: LineRuler!
    private var paragraph: NSParagraphStyle
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
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
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
                }
            })
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func applyTheme(_ theme: AppTheme) {
        guard appliedTheme != theme else { return }
        appliedTheme = theme
        appearance = NSAppearance(named: theme == .light ? .aqua : .darkAqua)
        scrollView.backgroundColor = EditorPalette.background(for: theme)
        textView.backgroundColor = EditorPalette.background(for: theme)
        gutter.needsDisplay = true
    }

    func applyZoom(_ scale: Double) {
        guard appliedZoom != scale else { return }
        appliedZoom = scale
        let history = textView.undoManager
        history?.disableUndoRegistration()
        defer { history?.enableUndoRegistration() }
        let font = Theme.nativeCodeFont(scale: scale)
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
        if window != nil {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.document?.focusEditorOnOpen != false { self.window?.makeFirstResponder(self.textView) }
                self.scheduleHighlight()
            }
        }
    }

    override func layout() {
        super.layout()
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
            document?.markTextStale()
            if document?.isDirty == false { document?.isDirty = true }
            gutter.updateThickness()
            gutter.needsDisplay = true
            scheduleHighlight()
        }
    }

    func textDidChange(_ notification: Notification) {
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
            guard !Task.isCancelled, let self, self.editRevision == revision else { return }
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
        updateLoadingAnimation()
    }

    func updateLoadingAnimation() {
        let loading = surface?.document?.queryMarkers.values.contains { $0.status == .loading } == true
        guard window != nil, loading else {
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
        let font = NSFont.monospacedSystemFont(ofSize: 12 * scale, weight: .regular)
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
            .font: NSFont.monospacedSystemFont(ofSize: 12 * scale, weight: .regular),
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
                let turn = CGFloat(Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.1) / 1.1 * 360)
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
