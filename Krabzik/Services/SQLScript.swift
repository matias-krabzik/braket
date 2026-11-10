import Foundation

struct SQLStatement: Sendable {
    let text: String
    let line: Int
}

/// Splits only at delimiters outside strings and comments. It is a cursor so the
/// server's NO_BACKSLASH_ESCAPES flag can be applied after each statement.
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
        var atLineStart = position == 0 || bytes[max(0, position - 1)] == 10

        func matches(_ token: [UInt8], at index: Int) -> Bool {
            index + token.count <= bytes.count && bytes[index..<(index + token.count)].elementsEqual(token)
        }

        while position < bytes.count {
            let c = bytes[position]
            let next = position + 1 < bytes.count ? bytes[position + 1] : 0
            if atLineStart && quote == nil && !blockComment && !lineComment && !hasSQL {
                let end = bytes[position...].firstIndex(of: 10) ?? bytes.count
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
                if c == 10 { lineComment = false }
            } else if blockComment {
                if c == 42 && next == 47 {
                    blockComment = false
                    position += 2
                    atLineStart = false
                    continue
                }
            } else if let active = quote {
                if c == 92 && active != 96 && !noBackslashEscapes && position + 1 < bytes.count {
                    if next == 10 { line += 1 }
                    position += 2
                    atLineStart = false
                    continue
                }
                if c == active {
                    if next == active {
                        position += 2
                        continue
                    }
                    quote = nil
                }
            } else if matches(delimiter, at: position) {
                let end = position
                position += delimiter.count
                if hasSQL {
                    return SQLStatement(text: String(decoding: bytes[start..<end], as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                                        line: startLine)
                }
                start = position
                startLine = line
                continue
            } else if c == 35 || (c == 45 && next == 45 && (position + 2 == bytes.count || bytes[position + 2] <= 32)) {
                lineComment = true
            } else if c == 47 && next == 42 {
                blockComment = true
                // Versioned executable comments (/*! ... */) are SQL, not decoration.
                if position + 2 < bytes.count && bytes[position + 2] == 33 { hasSQL = true }
                position += 2
                atLineStart = false
                continue
            } else if c == 39 || c == 34 || c == 96 {
                if !hasSQL { startLine = line }
                quote = c
                hasSQL = true
            } else if c > 32 {
                if !hasSQL { startLine = line }
                hasSQL = true
            }
            if c == 10 {
                line += 1
                atLineStart = true } else if c != 13 { atLineStart = false
            }
            position += 1
        }
        guard quote == nil, !blockComment else { throw DatabaseFailure("Texto o comentario sin cerrar desde la línea \(startLine).") }
        guard hasSQL else { return nil }
        return SQLStatement(text: String(decoding: bytes[start...], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
                            line: startLine)
    }
}
