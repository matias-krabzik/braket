import AppKit
import CodeEditLanguages
import SwiftTreeSitter

/// Resolución compartida entre la etiqueta del documento y su gramática real.
@MainActor enum SyntaxLanguage {
    static func resolve(_ url: URL) -> CodeLanguage {
        CodeLanguage.detectLanguageFrom(url: url)
    }

    static func name(_ url: URL) -> String {
        let language = resolve(url)
        switch language.id {
        case .plainText: return "Texto"
        case .javascript, .jsx: return "JavaScript"
        case .typescript, .tsx: return "TypeScript"
        case .sql: return "SQL"
        case .php: return "PHP"
        case .html: return "HTML"
        case .css: return "CSS"
        case .json: return "JSON"
        default: return language.tsName.capitalized
        }
    }
}

struct SyntaxSpan: Sendable {
    let range: NSRange
    let token: String

    @MainActor var color: NSColor {
        let category = token.split(separator: ".").first.map(String.init) ?? token
        switch category {
        case "comment": return EditorPalette.muted
        case "string", "character": return EditorPalette.green
        case "number", "float", "boolean", "constant": return EditorPalette.orange
        case "keyword", "conditional", "repeat", "include", "exception", "operator": return EditorPalette.purple
        case "function", "method", "type", "constructor", "tag", "attribute": return EditorPalette.blue
        default: return EditorPalette.text
        }
    }
}

/// Todos los objetos mutables de Tree-sitter y la copia de texto viven en este actor.
/// Recibe deltas UTF-16; nunca copia el documento completo por pulsación en el hilo de UI.
actor SyntaxParser {
    private let source: NSMutableString
    private var lines: LineIndex
    private let parser = Parser()
    private let query: Query?
    private var tree: MutableTree?
    private var needsParse = true
    private var ready = false

    init(text: String, language: Language?, query: Query?) {
        source = NSMutableString(string: text)
        lines = LineIndex(text)
        self.query = query
        if let language {
            do {
                try parser.setLanguage(language)
                parser.timeout = 0.25
                ready = true
            } catch {
                NSLog("Tree-sitter: no se pudo cargar la gramática: %@", String(describing: error))
            }
        }
    }

    func replace(_ range: NSRange, with replacement: String) {
        guard range.location >= 0, NSMaxRange(range) <= source.length else { return }
        let start = point(at: range.location)
        let oldEnd = point(at: NSMaxRange(range))
        source.replaceCharacters(in: range, with: replacement)
        lines.replace(range, with: replacement)
        let newEndOffset = range.location + replacement.utf16.count
        tree?.edit(InputEdit(startByte: range.location * 2, oldEndByte: NSMaxRange(range) * 2,
                             newEndByte: newEndOffset * 2, startPoint: start,
                             oldEndPoint: oldEnd, newEndPoint: point(at: newEndOffset)))
        needsParse = true
    }

    private func point(at offset: Int) -> Point {
        let row = lines.line(at: offset)
        return Point(row: row, column: (offset - lines.start(of: row)) * 2)
    }

    func highlights(in range: NSRange) -> [SyntaxSpan] {
        guard ready, let query, range.length > 0, NSMaxRange(range) <= source.length else { return [] }
        if needsParse {
            tree = parser.parse(tree: tree) { [source] byteOffset, _ in
                let offset = byteOffset / 2
                guard offset < source.length else { return nil }
                let count = min(2048, source.length - offset)
                var units = [unichar](repeating: 0, count: count)
                source.getCharacters(&units, range: NSRange(location: offset, length: count))
                return units.withUnsafeBytes { Data($0) }
            }
            guard tree != nil else {
                parser.reset()
                return []
            }
            needsParse = false
        }
        guard let tree else { return [] }
        let cursor = query.execute(in: tree)
        cursor.setRange(range)
        let context = Predicate.Context { [source] range, _ in
            guard NSMaxRange(range) <= source.length else { return nil }
            return source.substring(with: range)
        }
        let captures = cursor.filter { $0.allowed(in: context) }.flatMap(\.captures).sorted()
        return captures.compactMap { capture in
            let clipped = NSIntersectionRange(capture.range, range)
            guard clipped.length > 0, let name = capture.name, name != "spell" else { return nil }
            return SyntaxSpan(range: clipped, token: name)
        }
    }
}

/// Encadena deltas y consultas para mantener el orden incluso al escribir y deshacer rápidamente.
@MainActor final class SyntaxHighlighter {
    private let parser: SyntaxParser
    private var pending: Task<Void, Never>?

    init(text: String, url: URL) {
        let language = SyntaxLanguage.resolve(url)
        let query = Self.query(for: language)
        parser = SyntaxParser(text: text, language: language.language, query: query)
    }

    private static func query(for code: CodeLanguage) -> Query? {
        guard let language = code.language, let url = code.queryURL else { return nil }
        var urls = code.parentQueryURL.map { [$0] } ?? []
        urls.append(url)
        for name in (code.additionalHighlights ?? []).sorted() where name.hasPrefix("highlights") {
            urls.append(url.deletingLastPathComponent().appendingPathComponent(name + ".scm"))
        }
        do {
            var source = try urls.map { try String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
            // La consulta SQL upstream usa patrones Lua; el evaluador Swift usa ICU.
            if code.id == .sql { source = source.replacingOccurrences(of: "%d", with: "[0-9]") }
            return try Query(language: language, data: Data(source.utf8))
        } catch {
            NSLog("Tree-sitter: consulta %@: %@", code.tsName, String(describing: error))
            return nil
        }
    }

    func replace(_ range: NSRange, with text: String) {
        let previous = pending
        let parser = parser
        pending = Task {
            await previous?.value
            await parser.replace(range, with: text)
        }
    }

    func highlights(in range: NSRange) async -> [SyntaxSpan] {
        await pending?.value
        return await parser.highlights(in: range)
    }

    static func apply(_ spans: [SyntaxSpan], to storage: NSTextStorage, range: NSRange) {
        guard NSMaxRange(range) <= storage.length else { return }
        storage.beginEditing()
        storage.addAttribute(.foregroundColor, value: EditorPalette.text, range: range)
        for span in spans where NSMaxRange(span.range) <= storage.length {
            storage.addAttribute(.foregroundColor, value: span.color, range: span.range)
        }
        storage.endEditing()
    }
}
