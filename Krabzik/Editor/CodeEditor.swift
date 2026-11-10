import AppKit
import SwiftUI

enum EditorPalette {
    @MainActor static var background: NSColor {
        background(for: AppSettings.shared.theme)
    }
    static func background(for theme: AppTheme) -> NSColor {
        theme == .graphite
            ? NSColor(srgbRed: 0.122, green: 0.125, blue: 0.137, alpha: 1)
            : NSColor(calibratedRed: 0.105, green: 0.116, blue: 0.137, alpha: 1)
    }
    static let text = NSColor(srgbRed: 0.89, green: 0.90, blue: 0.92, alpha: 1)
    static let muted = NSColor(srgbRed: 0.53, green: 0.55, blue: 0.59, alpha: 1)
    static let blue = NSColor(calibratedRed: 0.49, green: 0.72, blue: 0.97, alpha: 1)
    static let purple = NSColor(calibratedRed: 0.76, green: 0.61, blue: 0.93, alpha: 1)
    static let green = NSColor(calibratedRed: 0.60, green: 0.77, blue: 0.65, alpha: 1)
    static let orange = NSColor(calibratedRed: 0.87, green: 0.70, blue: 0.52, alpha: 1)
}

struct CodeEditor: NSViewRepresentable {
    let document: EditorDocument
    let theme: AppTheme

    func makeNSView(context: Context) -> EditorSurface {
        if let existing = document.editorStorage as? EditorSurface { return existing }
        let surface = EditorSurface(document: document)
        document.editorStorage = surface
        return surface
    }

    func updateNSView(_ view: EditorSurface, context: Context) {
        view.applyTheme(theme)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: EditorSurface, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 700, height: proposal.height ?? 400)
    }
}

final class CodeTextView: NSTextView {
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
    var lines: LineIndex
    private var highlighter: DispatchWorkItem?
    private var scrollObserver: ObserverToken?
    private var gutter: LineRuler!
    private var paragraph: NSParagraphStyle
    private var editRevision = 0
    private var highlightedRevision = -1
    private var highlightedRange = NSRange(location: NSNotFound, length: 0)
    private var appliedTheme: AppTheme?

    init(document: EditorDocument) {
        self.document = document
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
        textView.insertionPointColor = .white
        textView.defaultParagraphStyle = paragraph
        textView.typingAttributes = baseAttributes
        textView.string = document.text
        textView.textStorage?.setAttributes(baseAttributes, range: NSRange(location: 0, length: (document.text as NSString).length))
        textView.delegate = self
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
        scrollView.backgroundColor = EditorPalette.background(for: theme)
        textView.backgroundColor = EditorPalette.background(for: theme)
        gutter.needsDisplay = true
    }

    func reloadFromDocument() {
        guard let document else { return }
        let selection = textView.selectedRange()
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
        scrollObserver = nil
        highlighter?.cancel()
        highlighter = nil
    }

    private var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), .foregroundColor: EditorPalette.text, .paragraphStyle: paragraph]
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
        if let replacementString { lines.replace(affectedCharRange, with: replacementString) }
        return true
    }

    func textDidChange(_ notification: Notification) {
        editRevision += 1
        document?.markTextStale()
        if document?.isDirty == false { document?.isDirty = true }
        textView.typingAttributes = baseAttributes
        gutter.needsDisplay = true
        scheduleHighlight()
        updatePosition()
    }

    func textViewDidChangeSelection(_ notification: Notification) { updatePosition() }

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
        let range = (storage.string as NSString).lineRange(for: NSRange(location: start, length: min(end - start, 40_000)))
        guard range.length <= 60_000 else { return }
        guard highlightedRevision != editRevision || highlightedRange != range else { return }
        highlightedRevision = editRevision
        highlightedRange = range
        SyntaxStyler.apply(to: storage, range: range, language: document?.language ?? "Texto")
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
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
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
            label.draw(at: NSPoint(x: self.ruleThickness - size.width - 12, y: y), withAttributes: attributes)
            return true
        }
    }
}

enum SyntaxStyler {
    /// Palabras clave que se colorean. La lista conserva el orden con el que se escribió
    /// y la expresión **distingue mayúsculas**: las de SQL están en mayúsculas porque es
    /// la convención con la que se escribe, y por eso `select` en minúsculas no se colorea
    /// (lo fija `SyntaxStylerTests.testUppercaseKeywordsEndUpWithTheTypeColor`).
    private static let keywords = [
        "class", "struct", "enum", "protocol", "extension", "func", "function", "public",
        "private", "protected", "static", "final", "let", "var", "const", "return",
        "if", "else", "for", "while", "switch", "case", "break", "continue",
        "import", "use", "namespace", "extends", "implements", "new", "async", "await",
        "try", "catch", "throw", "throws", "in", "where", "guard", "self",
        "this", "export", "from", "default", "interface", "type", "SELECT", "FROM",
        "WHERE", "INSERT", "INTO", "VALUES", "CREATE", "TABLE", "JOIN", "ON",
        "ORDER", "BY", "LIMIT", "UPDATE", "SET", "DELETE", "PRIMARY", "KEY",
        "NOT", "NULL", "INT", "VARCHAR", "DECIMAL"
    ]
    private static let tokens: [(NSRegularExpression, NSColor)] = [
        (#"\b("# + keywords.joined(separator: "|") + #")\b"#, EditorPalette.purple),
        (#"\b(true|false|nil|null|undefined|\d+(\.\d+)?)\b"#, EditorPalette.orange),
        (#"\b[A-Z][A-Za-z0-9_]*\b"#, EditorPalette.blue),
        (#"\$[A-Za-z_][A-Za-z0-9_]*"#, EditorPalette.purple),
        (#"\b[a-zA-Z_]\w*(?=\s*\()"#, EditorPalette.blue)
    ]
    // Las expresiones son literales de este archivo y las cubre
    // SyntaxStylerTests.testPatternsCompile, así que un `try!` falla en las pruebas, antes
    // de llegar a la app. Antes esto era `try?` + compactMap: un patrón roto desaparecía
    // en silencio y el editor coloreaba de menos sin que nada lo dijera.
    // swiftlint:disable force_try
    .map { pattern, color in (try! NSRegularExpression(pattern: pattern), color) }

    private static let literals =
        try! NSRegularExpression(pattern:
            #"(\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`)"#   // cadenas entre ", ' o `
            + #"|(//[^\n]*|/\*[\s\S]*?\*/|(?m)^\s*--[^\n]*)"#)   // comentarios //, /* */ y --
    // swiftlint:enable force_try

    static func apply(to storage: NSTextStorage, range: NSRange, language: String) {
        guard language != "Texto", language != "Markdown", range.length > 0 else { return }
        let segment = (storage.string as NSString).substring(with: range)
        storage.beginEditing()
        storage.addAttribute(.foregroundColor, value: EditorPalette.text, range: range)
        for (regex, color) in tokens {
            for match in regex.matches(in: segment, range: NSRange(location: 0, length: (segment as NSString).length)) {
                storage.addAttribute(.foregroundColor, value: color,
                                     range: NSRange(location: range.location + match.range.location, length: match.range.length))
            }
        }
        for match in literals.matches(in: segment, range: NSRange(location: 0, length: (segment as NSString).length)) {
            let color = match.range(at: 1).location == NSNotFound ? EditorPalette.muted : EditorPalette.green
            storage.addAttribute(.foregroundColor, value: color,
                                 range: NSRange(location: range.location + match.range.location, length: match.range.length))
        }
        storage.endEditing()
    }
}
