import Foundation

/// Valores locales: nunca evalúa expresiones ni envía el literal al servidor.
enum SQLListLiteral {
    static func parse(_ source: String, noBackslashEscapes: Bool) throws -> [SQLClientList.Element] {
        let scan = SQLScript.scan(source, noBackslashEscapes: noBackslashEscapes, collectSyntax: true)
        guard !scan.hasExecutableComment else { throw invalid() }
        let clean = NSMutableString(string: source)
        for span in scan.syntax.reversed() where span.token == "comment" {
            clean.replaceCharacters(in: span.range, with: String(repeating: " ", count: span.range.length))
        }
        let text = clean as String
        let masked = SQLListStatement.code(text, noBackslashEscapes: noBackslashEscapes) as NSString
        let original = text as NSString
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [] }
        var starts = [0]
        for index in 0..<masked.length where masked.character(at: index) == 44 { starts.append(index + 1) }
        guard starts.count <= 10_000 else { throw DatabaseFailure("La lista supera 10.000 elementos.") }
        var values: [SQLClientList.Element] = []
        for (index, start) in starts.enumerated() {
            let end = index + 1 < starts.count ? starts[index + 1] - 1 : original.length
            let item = original.substring(with: NSRange(location: start, length: end - start))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if item.uppercased() == "NULL" { continue }
            if item.hasPrefix("'") || item.hasPrefix("\"") {
                values.append(.text(try string(item, noBackslashEscapes: noBackslashEscapes)))
            } else if item.range(of: #"^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$"#,
                                 options: .regularExpression) != nil {
                values.append(.number(item))
            } else { throw invalid() }
        }
        return values
    }

    private static func string(_ source: String, noBackslashEscapes: Bool) throws -> String {
        let chars = Array(source)
        guard let quote = chars.first, chars.count >= 2 else { throw invalid() }
        var value = "", index = 1
        while index < chars.count {
            let char = chars[index]
            if char == quote {
                if index + 1 < chars.count, chars[index + 1] == quote {
                    value.append(quote)
                    index += 2
                    continue
                }
                guard index == chars.count - 1 else { throw invalid() }
                return value
            }
            if char == "\\", !noBackslashEscapes {
                index += 1
                guard index < chars.count else { throw invalid() }
                let escaped = chars[index]
                let escapes: [Character: Character] = ["0": "\0", "b": "\u{8}", "n": "\n", "r": "\r", "t": "\t", "Z": "\u{1A}"]
                if escaped == "%" || escaped == "_" { value.append("\\") }
                value.append(escapes[escaped] ?? escaped)
            } else { value.append(char) }
            index += 1
        }
        throw invalid()
    }

    private static func invalid() -> DatabaseFailure {
        DatabaseFailure("Usá una lista de textos entre comillas o números: SET LIST nombre = ['texto', 123].")
    }
}
