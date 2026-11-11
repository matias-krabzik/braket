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

struct SyntaxGrammar: Sendable {
    let language: Language
    let query: Query
}

/// Confinado a SyntaxParser; nunca cruza el límite del actor.
private final class EmbeddedSyntax {
    let name: String
    let parser = Parser()
    var tree: MutableTree?
    var needsParse = true

    init?(name: String, grammar: SyntaxGrammar) {
        self.name = name
        do {
            try parser.setLanguage(grammar.language)
        } catch {
            NSLog("Tree-sitter: gramática incrustada %@: %@", name, String(describing: error))
            return nil
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
    private let injections: Query?
    private let embeddedLanguages: [String: SyntaxGrammar]
    private var embedded: [EmbeddedSyntax] = []
    private var ready = false

    init(text: String, language: Language?, query: Query?, injections: Query? = nil,
         embeddedLanguages: [String: SyntaxGrammar] = [:]) {
        source = NSMutableString(string: text)
        lines = LineIndex(text)
        self.query = query
        self.injections = injections
        self.embeddedLanguages = embeddedLanguages
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
        let edit = InputEdit(startByte: range.location * 2, oldEndByte: NSMaxRange(range) * 2,
                             newEndByte: newEndOffset * 2, startPoint: start,
                             oldEndPoint: oldEnd, newEndPoint: point(at: newEndOffset))
        tree?.edit(edit)
        for layer in embedded {
            layer.tree?.edit(edit)
            layer.needsParse = true
        }
        needsParse = true
    }

    private func point(at offset: Int) -> Point {
        let row = lines.line(at: offset)
        return Point(row: row, column: (offset - lines.start(of: row)) * 2)
    }

    func highlights(in range: NSRange) -> [SyntaxSpan] {
        guard ready, let query, range.length > 0, NSMaxRange(range) <= source.length else { return [] }
        let deadline = Date.timeIntervalSinceReferenceDate + 0.25
        if needsParse {
            tree = parser.parse(tree: tree, readBlock: read)
            guard tree != nil else {
                parser.reset()
                return []
            }
            needsParse = false
        }
        guard let tree else { return [] }
        var result = captures(query: query, tree: tree, range: range)
        result += embeddedHighlights(in: range, tree: tree, deadline: deadline)
        return result
    }

    private func read(byteOffset: Int, point: Point) -> Data? {
        let offset = byteOffset / 2
        guard offset < source.length else { return nil }
        let count = min(2048, source.length - offset)
        var units = [unichar](repeating: 0, count: count)
        source.getCharacters(&units, range: NSRange(location: offset, length: count))
        return units.withUnsafeBytes { Data($0) }
    }

    private func captures(query: Query, tree: MutableTree, range: NSRange) -> [SyntaxSpan] {
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

    private func embeddedHighlights(in range: NSRange, tree: MutableTree, deadline: TimeInterval) -> [SyntaxSpan] {
        guard let injections else { return [] }
        let cursor = injections.execute(in: tree)
        cursor.setRange(range)
        var active: [EmbeddedSyntax] = []
        var result: [SyntaxSpan] = []
        for match in cursor {
            guard let content = match.captures.first,
                  let name = embeddedLanguage(for: content), let grammar = embeddedLanguages[name] else { continue }
            let region = content.range
            guard region.length > 0 else { continue }
            let included = TSRange(points: point(at: region.location)..<point(at: NSMaxRange(region)),
                                   bytes: UInt32(region.location * 2)..<UInt32(NSMaxRange(region) * 2))
            // Un árbol por bloque: un comentario sin cerrar no contamina el siguiente <script>.
            let cached = embedded.first { $0.name == name && $0.tree?.includedRanges == [included] }
            guard let layer = cached ?? EmbeddedSyntax(name: name, grammar: grammar) else { continue }
            active.append(layer)
            if layer.needsParse {
                let remaining = deadline - Date.timeIntervalSinceReferenceDate
                guard remaining > 0 else { continue }
                layer.parser.includedRanges = [included]
                layer.parser.timeout = remaining
                layer.tree = layer.parser.parse(tree: layer.tree, readBlock: read)
                guard layer.tree != nil else {
                    layer.parser.reset()
                    continue
                }
                layer.needsParse = false
            }
            guard let childTree = layer.tree else { continue }
            let visible = NSIntersectionRange(region, range)
            result.append(SyntaxSpan(range: visible, token: "none"))
            result += captures(query: grammar.query, tree: childTree, range: visible)
        }
        // Solo conservar los bloques visibles evita retener árboles para todo un HTML grande.
        embedded = active
        return result
    }

    private func embeddedLanguage(for capture: QueryCapture) -> String? {
        // raw_text también existe dentro de ERROR cuando falta la etiqueta de cierre.
        guard let startTag = capture.node.previousNamedSibling, startTag.nodeType == "start_tag",
              let tagNode = startTag.namedChild(at: 0) else { return nil }
        let tag = source.substring(with: tagNode.range).lowercased()
        guard tag == "script" || tag == "style" else { return nil }
        var type = ""
        for index in 0..<startTag.namedChildCount {
            guard let attribute = startTag.namedChild(at: index), attribute.nodeType == "attribute",
                  let name = attribute.namedChild(at: 0),
                  source.substring(with: name.range).lowercased() == "type",
                  let value = attribute.namedChild(at: 1) else { continue }
            type = source.substring(with: value.range)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"' \t\r\n")).lowercased()
        }
        let mime = type.split(separator: ";").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        if tag == "style" { return mime.isEmpty || mime == "text/css" ? "css" : nil }
        switch mime {
        case "", "module", "text/javascript", "application/javascript", "text/ecmascript", "application/ecmascript":
            return "javascript"
        case "application/json", "application/ld+json", "importmap", "speculationrules": return "json"
        default: return nil
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
        var injections: Query?
        var embeddedLanguages: [String: SyntaxGrammar] = [:]
        if language.id == .html, let html = language.language {
            do {
                let patterns = "(raw_text) @embedded"
                injections = try Query(language: html, data: Data(patterns.utf8))
                for code in [CodeLanguage.javascript, .css, .json] {
                    if let language = code.language, let query = Self.query(for: code) {
                        embeddedLanguages[code.tsName] = SyntaxGrammar(language: language, query: query)
                    }
                }
            } catch {
                NSLog("Tree-sitter: inyecciones HTML: %@", String(describing: error))
            }
        }
        parser = SyntaxParser(text: text, language: language.language, query: query,
                              injections: injections, embeddedLanguages: embeddedLanguages)
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
