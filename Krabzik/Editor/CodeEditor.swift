import AppKit
import SwiftUI

enum EditorPalette {
    @MainActor static var background: NSColor {
        background(for: AppSettings.shared.theme)
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
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: EditorSurface, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 700, height: proposal.height ?? 400)
    }
}

final class CodeTextView: NSTextView {
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

@MainActor final class EditorSurface: NSView, NSTextViewDelegate {
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

    init(document: EditorDocument) {
        self.document = document
        self.syntax = SyntaxHighlighter(text: document.text, url: document.url)
        self.lines = LineIndex(document.text)
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = 23
        style.maximumLineHeight = 23
        style.tabStops = []
        style.defaultTabInterval = 32
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
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = EditorPalette.text
        textView.backgroundColor = EditorPalette.background
        textView.insertionPointColor = EditorPalette.text
        textView.defaultParagraphStyle = paragraph
        textView.typingAttributes = baseAttributes
        textView.string = document.text
        textView.textStorage?.setAttributes(baseAttributes, range: NSRange(location: 0, length: (document.text as NSString).length))
        textView.delegate = self
        textView.requestCompletion = { [weak self] in
            guard let self, let completion = self.completion else { return }
            let values = completion(self.textView.string, self.textView.selectedRange().location)
            self.suggestions.show(values, in: self, textView: self.textView)
        }
        textView.completionKey = { [weak self] event in self?.suggestions.handle(event) ?? false }
        suggestions.accept = { [weak self] value in
            guard let self else { return }
            self.window?.makeFirstResponder(self.textView)
            self.textView.insertText(value, replacementRange: self.textView.rangeForUserCompletion)
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
        let font = NSFont.monospacedSystemFont(ofSize: 13 * CGFloat(scale), weight: .regular)
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = 23 * CGFloat(scale)
        style.maximumLineHeight = 23 * CGFloat(scale)
        style.tabStops = []
        style.defaultTabInterval = 32 * CGFloat(scale)
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
        gutter.ruleThickness = 54 * CGFloat(scale)
        gutter.needsDisplay = true
        textView.needsLayout = true
    }

    func reloadFromDocument() {
        guard let document else { return }
        let selection = textView.selectedRange()
        syntax = SyntaxHighlighter(text: document.text, url: document.url)
        highlightTask?.cancel()
        textView.string = document.text
        lines = LineIndex(document.text)
        textView.undoManager?.removeAllActions()
        textView.textStorage?.setAttributes(baseAttributes, range: NSRange(location: 0, length: (document.text as NSString).length))
        textView.setSelectedRange(NSRange(location: min(selection.location, (document.text as NSString).length), length: 0))
        editRevision += 1
        gutter.needsDisplay = true
        scheduleHighlight()
        updatePosition()
    }

    /// Expuesto para las pruebas: indica si el surface sigue observando el scroll.
    var isObservingScroll: Bool { scrollObserver != nil }

    /// Limpieza determinista, idempotente. La llama el documento al cerrarse.
    /// No se hace en `deinit` porque es `nonisolated` y no puede tocar estas propiedades.
    /// Si nadie la llama, `ObserverToken` quita el observador al liberarse y el resaltado
    /// pendiente no hace nada, porque captura `self` de forma débil.
    func teardown() {
        completionWork?.cancel()
        suggestions.hide()
        scrollObserver = nil
        highlighter?.cancel()
        highlighter = nil
        highlightTask?.cancel()
    }

    private var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.monospacedSystemFont(ofSize: 13 * CGFloat(appliedZoom), weight: .regular),
         .foregroundColor: EditorPalette.text, .paragraphStyle: paragraph]
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.window?.makeFirstResponder(self.textView)
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

    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        if let replacementString {
            syntax.replace(affectedCharRange, with: replacementString)
            lines.replace(affectedCharRange, with: replacementString)
        }
        return true
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
        editRevision += 1
        document?.markTextStale()
        if document?.isDirty == false { document?.isDirty = true }
        textView.typingAttributes = baseAttributes
        gutter.needsDisplay = true
        scheduleHighlight()
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
            SyntaxHighlighter.apply(spans, to: storage, range: range)
        }
    }
}

@MainActor final class LineRuler: NSRulerView {
    weak var surface: EditorSurface?

    init(surface: EditorSurface) {
        self.surface = surface
        super.init(scrollView: surface.scrollView, orientation: .verticalRuler)
        ruleThickness = 54
        clientView = surface.textView
        wantsLayer = true
        clipsToBounds = true
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        EditorPalette.background.setFill()
        bounds.fill()
        guard let surface, let layout = surface.textView.textLayoutManager,
              let content = layout.textContentManager,
              let viewport = layout.textViewportLayoutController.viewportRange else { return }
        let visible = surface.scrollView.contentView.bounds
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: Theme.zoom(11), weight: .regular),
            .foregroundColor: EditorPalette.muted
        ]
        layout.enumerateTextLayoutFragments(from: viewport.location, options: []) { fragment in
            let frame = fragment.layoutFragmentFrame
            if frame.minY > visible.maxY { return false }
            let offset = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
            let number = surface.lines.line(at: offset) + 1
            let label = "\(number)" as NSString
            let size = label.size(withAttributes: attributes)
            let y = frame.minY + surface.textView.textContainerInset.height - visible.minY + 4
            label.draw(at: NSPoint(x: self.ruleThickness - size.width - Theme.zoom(12), y: y), withAttributes: attributes)
            return true
        }
    }
}
