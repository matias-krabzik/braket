import Foundation

struct SQLCommentEdit: Sendable {
    let range: NSRange
    let replacement: String
    let uncommenting: Bool
    var selection: NSRange { NSRange(location: range.location, length: replacement.utf16.count) }
}

enum SQLCommentToggle {
    /// La selección parcial afecta sus líneas completas. Conserva indentación y finales de línea.
    static func edit(in text: String, selection: NSRange) -> SQLCommentEdit? {
        let source = text as NSString
        guard selection.location >= 0, selection.location <= source.length, selection.length > 0,
              selection.length <= source.length - selection.location else { return nil }
        let selected = source.substring(with: selection)
        guard !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let trimmed = selected.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("/*"), trimmed.hasSuffix("*/"), !trimmed.hasPrefix("/*!"), !trimmed.hasPrefix("/*M!") {
            let tokens = SQLScript.scan(trimmed, collectSyntax: true).syntax
            if tokens.count == 1, tokens[0].token == "comment", tokens[0].range.length == trimmed.utf16.count {
                let range = (selected as NSString).range(of: trimmed)
                let unwrapped = String(trimmed.dropFirst(2).dropLast(2))
                let replacement = (selected as NSString).replacingCharacters(in: range, with: unwrapped)
                return SQLCommentEdit(range: selection, replacement: replacement, uncommenting: true)
            }
        }
        let first = source.lineRange(for: NSRange(location: selection.location, length: 0)).location
        let last = source.lineRange(for: NSRange(location: NSMaxRange(selection) - 1, length: 0))
        let range = NSRange(location: first, length: NSMaxRange(last) - first)
        let original = source.substring(with: range) as NSString
        var lines: [(prefix: String, body: String, ending: String)] = []
        var offset = 0
        while offset < original.length {
            var start = 0, end = 0, contentsEnd = 0
            original.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: offset, length: 0))
            let content = original.substring(with: NSRange(location: start, length: contentsEnd - start))
            let prefix = String(content.prefix { $0 == " " || $0 == "\t" })
            let body = String(content.dropFirst(prefix.count))
            lines.append((prefix, body, original.substring(with: NSRange(location: contentsEnd, length: end - contentsEnd))))
            offset = end
        }
        let meaningful = lines.filter { !$0.body.isEmpty }
        let uncomment = !meaningful.isEmpty && meaningful.allSatisfy { markerLength($0.body) != nil }
        let replacement = lines.map { line in
            guard !line.body.isEmpty else { return line.prefix + line.ending }
            if uncomment, let count = markerLength(line.body) {
                var body = String(line.body.dropFirst(count))
                if body.hasPrefix(" ") { body.removeFirst() }
                return line.prefix + body + line.ending
            }
            return line.prefix + "-- " + line.body + line.ending
        }.joined()
        return SQLCommentEdit(range: range, replacement: replacement, uncommenting: uncomment)
    }

    private static func markerLength(_ body: String) -> Int? {
        if body.hasPrefix("#") { return 1 }
        guard body.hasPrefix("--") else { return nil }
        let rest = body.dropFirst(2)
        return rest.isEmpty || rest.first?.isWhitespace == true ? 2 : nil
    }
}
