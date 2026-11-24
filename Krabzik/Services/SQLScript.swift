import Foundation

/// Una sentencia del script, con la línea donde empieza para poder señalar el error en
/// el editor.
struct SQLStatement: Sendable {
    let text: String
    let line: Int
    var range = NSRange(location: 0, length: 0)
    var delimiter = ";"
}

/// Bytes que el parser reconoce. Con los números a la vista, cada comparación de este
/// archivo había que traducirla mentalmente. Ver docs/specs/C4-legibilidad.md.
private enum Byte {
    static let newline: UInt8 = 10
    static let carriageReturn: UInt8 = 13
    static let space: UInt8 = 32
    /// `/*!` marca un comentario ejecutable: es SQL, no decoración.
    static let exclamation: UInt8 = 33
    static let doubleQuote: UInt8 = 34
    static let hash: UInt8 = 35
    static let singleQuote: UInt8 = 39
    static let openParen: UInt8 = 40
    static let closeParen: UInt8 = 41
    static let asterisk: UInt8 = 42
    static let hyphen: UInt8 = 45
    static let slash: UInt8 = 47
    static let zero: UInt8 = 48
    static let nine: UInt8 = 57
    static let uppercaseA: UInt8 = 65
    /// `/*M!` es la variante de MariaDB del comentario ejecutable.
    static let uppercaseM: UInt8 = 77
    static let uppercaseZ: UInt8 = 90
    static let backslash: UInt8 = 92
    static let underscore: UInt8 = 95
    static let backtick: UInt8 = 96
    static let lowercaseA: UInt8 = 97
    static let lowercaseZ: UInt8 = 122
}

/// Corta un script en sentencias, solo en los delimitadores que están fuera de cadenas y
/// comentarios.
///
/// Es un **cursor** y no una función que devuelva un arreglo: el servidor puede cambiar
/// `NO_BACKSLASH_ESCAPES` en medio del script, y entonces lo que es un escape y lo que es
/// una comilla cambia para las sentencias que siguen. Quien lo usa pasa el valor vigente
/// en cada llamada a `next(noBackslashEscapes:)`.
///
/// No es `Sendable`: el estado de posición y línea es de quien lo recorre.
struct SQLScript {
    private let bytes: [UInt8]
    private var position = 0
    private var line = 1
    private var delimiter = [UInt8](";".utf8)

    init(_ text: String, startingLine: Int = 1) {
        bytes = Array(text.utf8)
        line = startingLine
    }

    mutating func next(noBackslashEscapes: Bool = false) throws -> SQLStatement? {
        var start = position, startLine = line
        var quote: UInt8?
        var blockComment = false, lineComment = false, hasSQL = false
        var atLineStart = position == 0 || bytes[max(0, position - 1)] == Byte.newline

        func matches(_ token: [UInt8], at index: Int) -> Bool {
            index + token.count <= bytes.count && bytes[index..<(index + token.count)].elementsEqual(token)
        }

        while position < bytes.count {
            let byte = bytes[position]
            let following = position + 1 < bytes.count ? bytes[position + 1] : 0
            if atLineStart && quote == nil && !blockComment && !lineComment && !hasSQL {
                let end = bytes[position...].firstIndex(of: Byte.newline) ?? bytes.count
                let directive = String(decoding: bytes[position..<end], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if directive.uppercased().hasPrefix("DELIMITER ") || directive.uppercased().hasPrefix("DELIMITER\t") {
                    let value = directive.dropFirst(9).trimmingCharacters(in: .whitespaces)
                    guard !value.isEmpty, value.utf8.count <= 16, !value.contains(where: \.isWhitespace),
                          !value.contains("'"), !value.contains("\""), !value.contains("`") else {
                        throw DatabaseFailure("DELIMITER no válido en la línea \(line).")
                    }
                    delimiter = Array(value.utf8)
                    position = end < bytes.count ? end + 1 : end
                    if end < bytes.count { line += 1 }
                    start = position
                    startLine = line
                    atLineStart = true
                    continue
                }
            }
            if lineComment {
                if byte == Byte.newline { lineComment = false }
            } else if blockComment {
                if byte == Byte.asterisk && following == Byte.slash {
                    blockComment = false
                    position += 2
                    atLineStart = false
                    continue
                }
            } else if let active = quote {
                if byte == Byte.backslash, active != Byte.backtick, !noBackslashEscapes,
                   position + 1 < bytes.count {
                    if following == Byte.newline { line += 1 }
                    position += 2
                    atLineStart = false
                    continue
                }
                if byte == active {
                    if following == active {
                        position += 2
                        continue
                    }
                    quote = nil
                }
            } else if matches(delimiter, at: position) {
                let end = position
                position += delimiter.count
                if hasSQL {
                    return statement(start: start, end: end, line: startLine, rangeEnd: position)
                }
                start = position
                startLine = line
                continue
            } else if byte == Byte.hash
                || (byte == Byte.hyphen && following == Byte.hyphen
                    && (position + 2 == bytes.count || bytes[position + 2] <= Byte.space)) {
                lineComment = true
            } else if byte == Byte.slash && following == Byte.asterisk {
                blockComment = true
                if position + 2 < bytes.count, bytes[position + 2] == Byte.exclamation { hasSQL = true }
                position += 2
                atLineStart = false
                continue
            } else if byte == Byte.singleQuote || byte == Byte.doubleQuote || byte == Byte.backtick {
                if !hasSQL { startLine = line }
                quote = byte
                hasSQL = true
            } else if byte > Byte.space {
                if !hasSQL { startLine = line }
                hasSQL = true
            }
            if byte == Byte.newline {
                line += 1
                atLineStart = true
            } else if byte != Byte.carriageReturn {
                atLineStart = false
            }
            position += 1
        }
        guard quote == nil, !blockComment else { throw DatabaseFailure("Texto o comentario sin cerrar desde la línea \(startLine).") }
        guard hasSQL else { return nil }
        return statement(start: start, end: bytes.count, line: startLine, rangeEnd: bytes.count)
    }

    private func statement(start: Int, end: Int, line: Int, rangeEnd: Int) -> SQLStatement {
        let prefix = String(decoding: bytes[..<start], as: UTF8.self)
        let covered = String(decoding: bytes[start..<rangeEnd], as: UTF8.self)
        return SQLStatement(text: String(decoding: bytes[start..<end], as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines), line: line,
                            range: NSRange(location: prefix.utf16.count, length: covered.utf16.count),
                            delimiter: String(decoding: delimiter, as: UTF8.self))
    }

    static func atCursor(in text: String, selection: NSRange, noBackslashEscapes: Bool = false) throws -> SQLStatement? {
        let source = text as NSString
        guard selection.location <= source.length, selection.length <= source.length - selection.location else { return nil }
        if selection.length > 0 {
            return SQLStatement(text: source.substring(with: selection),
                                line: source.substring(to: selection.location).filter { $0 == "\n" }.count + 1, range: selection)
        }
        let physicalLine = source.lineRange(for: selection)
        let line = source.substring(with: physicalLine).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, !line.hasPrefix("--"), !line.hasPrefix("#"), !line.uppercased().hasPrefix("DELIMITER ") else { return nil }
        var parser = SQLScript(text)
        while let statement = try parser.next(noBackslashEscapes: noBackslashEscapes) {
            let trailingLine = source.substring(with: NSRange(location: selection.location,
                                                              length: NSMaxRange(physicalLine) - selection.location))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if NSLocationInRange(selection.location, statement.range)
                || (selection.location == NSMaxRange(statement.range) && trailingLine.isEmpty) {
                return statement
            }
        }
        return nil
    }
}

/// Una palabra desnuda del SQL: el token en mayúsculas, dónde empieza —en bytes— y a qué
/// profundidad de paréntesis aparece. `depth == 0` es el nivel externo de la sentencia.
struct SQLWord: Sendable, Equatable {
    let word: String
    let offset: Int
    let depth: Int
}

/// Lo que queda de una sentencia cuando se saltea todo lo que no es código.
struct SQLLexeme: Sendable {
    let text: String
    let depth: Int
    var quoted = false
    var offset = 0
}

struct SQLWordScan: Sendable {
    var lexemes: [SQLLexeme] = []
    var syntax: [SyntaxSpan] = []
    /// Las palabras desnudas, en orden de aparición.
    var words: [SQLWord] = []
    /// `true` si hay un comentario ejecutable (`/*!` o `/*M!`) fuera de cadenas: eso es
    /// SQL que el servidor ejecuta, no decoración.
    var hasExecutableComment = false

    /// Las palabras del nivel externo, que son las que identifican la forma de la sentencia.
    var outer: [String] { words.filter { $0.depth == 0 }.map(\.word) }
}

extension SQLScript {
    /// Recorre `sql` con las mismas reglas de cadenas, identificadores entre backticks y
    /// comentarios que `next()`, y devuelve las palabras que quedan afuera.
    ///
    /// Es el **único** recorrido léxico del proyecto: lo usan la paginación, para reconocer
    /// cláusulas externas, y `SQLWriteGuard`, para decidir si una sentencia escribe. Un
    /// segundo recorrido con sus propias reglas sería garantizar que se separen.
    static func scan(_ sql: String, noBackslashEscapes: Bool = false, collectLexemes: Bool = false,
                     collectSyntax: Bool = false) -> SQLWordScan {
        let bytes = Array(sql.utf8)
        var index = 0, depth = 0
        var scan = SQLWordScan()
        var mappedByte = 0, mappedUTF16 = 0
        func emit(_ start: Int, _ end: Int, _ token: String) {
            guard collectSyntax else { return }
            mappedUTF16 += String(decoding: bytes[mappedByte..<start], as: UTF8.self).utf16.count
            let length = String(decoding: bytes[start..<end], as: UTF8.self).utf16.count
            scan.syntax.append(SyntaxSpan(range: NSRange(location: mappedUTF16, length: length), token: token))
            mappedByte = end
            mappedUTF16 += length
        }
        while index < bytes.count {
            let byte = bytes[index]
            let following = index + 1 < bytes.count ? bytes[index + 1] : 0
            if byte == Byte.singleQuote || byte == Byte.doubleQuote || byte == Byte.backtick {
                let start = index
                index = skipQuoted(bytes, from: index, noBackslashEscapes: noBackslashEscapes)
                index = min(index, bytes.count)
                emit(start, index, byte == Byte.backtick ? "type" : "string")
                if collectLexemes {
                    scan.lexemes.append(SQLLexeme(text: String(decoding: bytes[start..<min(index, bytes.count)], as: UTF8.self),
                                                  depth: depth, quoted: true, offset: start))
                }
            } else if byte == Byte.hash
                || (byte == Byte.hyphen && following == Byte.hyphen
                    && (index + 2 == bytes.count || bytes[index + 2] <= Byte.space)) {
                let start = index
                while index < bytes.count, bytes[index] != Byte.newline { index += 1 }
                emit(start, index, "comment")
            } else if byte == Byte.slash && following == Byte.asterisk {
                let start = index
                if executableComment(bytes, at: index) { scan.hasExecutableComment = true }
                index += 2
                while index + 1 < bytes.count, !(bytes[index] == Byte.asterisk && bytes[index + 1] == Byte.slash) {
                    index += 1
                }
                index = min(index + 2, bytes.count)
                emit(start, index, "comment")
            } else if collectSyntax, byte == 123, following == 123,
                      let end = bytes[(index + 2)...].firstIndex(of: 125), end + 1 < bytes.count, bytes[end + 1] == 125,
                      bytes[(index + 2)..<end].allSatisfy({ isWordByte($0) || $0 <= Byte.space }) {
                emit(index, end + 2, "variable.sql")
                index = end + 2
            } else if collectSyntax, byte == 64 {
                let start = index
                index += 1
                if index < bytes.count, bytes[index] == 64 { index += 1 }
                while index < bytes.count, isWordByte(bytes[index]) || bytes[index] == 46 || bytes[index] >= 128 { index += 1 }
                emit(start, index, "variable.sql")
            } else if collectSyntax, let end = syntaxNumberEnd(bytes, at: index) {
                emit(index, end, "number")
                index = end
            } else if byte == Byte.openParen {
                depth += 1
                index += 1
            } else if byte == Byte.closeParen {
                depth -= 1
                index += 1
            } else if isLetter(byte) || byte == Byte.underscore {
                let start = index
                while index < bytes.count, isWordByte(bytes[index]) { index += 1 }
                let word = String(decoding: bytes[start..<index], as: UTF8.self).uppercased()
                let followsSet = scan.words.last?.word == "SET"
                scan.words.append(SQLWord(word: word, offset: start, depth: depth))
                if collectSyntax, depth == 0, word == "LIST", followsSet { emit(start, index, "keyword") }
                if collectLexemes {
                    scan.lexemes.append(SQLLexeme(text: String(decoding: bytes[start..<index], as: UTF8.self), depth: depth, offset: start))
                }
            } else {
                if collectSyntax, [43, 45, 42, 47, 37, 61, 60, 62, 33, 124, 38, 94, 126, 58].contains(byte) {
                    emit(index, index + 1, "operator")
                }
                if collectLexemes, byte > Byte.space {
                    scan.lexemes.append(SQLLexeme(text: String(decoding: [byte], as: UTF8.self),
                                                  depth: depth, offset: index))
                }
                index += 1
            }
        }
        return scan
    }

    /// Cubre literales MySQL aun dentro de nodos ERROR de la gramática estructural.
    private static func syntaxNumberEnd(_ bytes: [UInt8], at start: Int) -> Int? {
        func digit(_ index: Int) -> Bool { index < bytes.count && (48...57).contains(bytes[index]) }
        guard start == 0 || (!isWordByte(bytes[start - 1]) && bytes[start - 1] < 128) else { return nil }
        guard digit(start) || (bytes[start] == 46 && digit(start + 1)) else { return nil }
        var end = start
        if bytes[start] == 48, start + 2 < bytes.count, [120, 88, 98, 66].contains(bytes[start + 1]) {
            let binary = [98, 66].contains(bytes[start + 1])
            end = start + 2
            while end < bytes.count, binary ? [48, 49].contains(bytes[end])
                : ((48...57).contains(bytes[end]) || (65...70).contains(bytes[end]) || (97...102).contains(bytes[end])) {
                end += 1
            }
            return end > start + 2 ? end : nil
        }
        while digit(end) { end += 1 }
        if end < bytes.count, bytes[end] == 46 {
            end += 1
            while digit(end) { end += 1 }
        }
        if end < bytes.count, [101, 69].contains(bytes[end]) {
            var exponent = end + 1
            if exponent < bytes.count, [43, 45].contains(bytes[exponent]) { exponent += 1 }
            if digit(exponent) {
                while digit(exponent) { exponent += 1 }
                end = exponent
            }
        }
        return end
    }

    /// Devuelve el índice que sigue a la cadena o identificador que empieza en `start`.
    /// Un backslash escapa el cierre salvo dentro de backticks o con `NO_BACKSLASH_ESCAPES`,
    /// y el delimitador duplicado no cierra: las mismas reglas que `next()`.
    private static func skipQuoted(_ bytes: [UInt8], from start: Int, noBackslashEscapes: Bool) -> Int {
        let quote = bytes[start]
        var index = start + 1
        while index < bytes.count {
            let byte = bytes[index]
            if byte == Byte.backslash, quote != Byte.backtick, !noBackslashEscapes {
                index += 2
                continue
            }
            if byte == quote {
                index += 1
                guard index < bytes.count, bytes[index] == quote else { return index }
                index += 1
                continue
            }
            index += 1
        }
        return index
    }

    private static func executableComment(_ bytes: [UInt8], at index: Int) -> Bool {
        guard index + 2 < bytes.count else { return false }
        if bytes[index + 2] == Byte.exclamation { return true }
        return index + 3 < bytes.count && bytes[index + 2] == Byte.uppercaseM && bytes[index + 3] == Byte.exclamation
    }

    private static func isLetter(_ byte: UInt8) -> Bool {
        (Byte.uppercaseA...Byte.uppercaseZ).contains(byte) || (Byte.lowercaseA...Byte.lowercaseZ).contains(byte)
    }

    private static func isWordByte(_ byte: UInt8) -> Bool {
        isLetter(byte) || (Byte.zero...Byte.nine).contains(byte) || byte == Byte.underscore
    }
}
