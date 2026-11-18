import Foundation

struct EditorOptions: Codable, Equatable, Sendable {
    var matchBrackets = true
    var rainbowBrackets = false
    var indentationGuides = true
    var autoClose = true
    var variableReferences = true
    var activeStatement = true
    var indentWidth = 4
    var keywordCase = "upper"
}

/// Una instantánea independiente del texto: nunca agrega atributos al historial de edición.
struct EditorStructure: Sendable {
    var pairs: [Int: Int] = [:]
    var depths: [Int: Int] = [:]
    var unmatched: Set<Int> = []
    let protected: [NSRange]
    let openEnds: Set<Int>
    let variables: [String: [NSRange]]
    let length: Int
    let indents: [Int]
    let delimiters: [Int]
    var statements: [NSRange] = []

    init(_ text: String, sql: Bool) {
        let source = text as NSString
        length = source.length
        indents = text.components(separatedBy: "\n").map { line in
            line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        }
        if sql {
            let tokens = SQLScript.scan(text, collectSyntax: true).syntax
            protected = tokens.filter { ["comment", "string", "type"].contains($0.token) }.map(\.range)
            var references: [String: [NSRange]] = [:]
            for token in tokens where token.token == "variable.sql" {
                references[source.substring(with: token.range).lowercased(), default: []].append(token.range)
            }
            variables = references
        } else {
            let pattern = #"(?s:/\*.*?(?:\*/|$))|//[^\r\n]*|#[^\r\n]*|"#
                + #"'(?:\\.|''|[^'\\])*(?:'|$)|"(?:\\.|""|[^"\\])*(?:"|$)|`(?:\\.|[^`\\])*(?:`|$)"#
            protected = (try? NSRegularExpression(pattern: pattern))?.matches(in: text,
                                                                              range: NSRange(location: 0, length: source.length))
                                                                              .map(\.range) ?? [
                                                                              ]
            variables = [:]
        }
        openEnds = Set(protected.compactMap { range in
            let region = source.substring(with: range)
            if region.hasPrefix("--") || region.hasPrefix("#") || region.hasPrefix("//") { return NSMaxRange(range) }
            if region.hasPrefix("/*") { return region.hasSuffix("*/") ? nil : NSMaxRange(range) }
            guard let first = region.first else { return nil }
            if region.count < 2 || region.last != first { return NSMaxRange(range) }
            let slashes = region.dropLast().reversed().prefix { $0 == "\\" }.count
            return slashes % 2 == 1 ? NSMaxRange(range) : nil
        })
        var stack: [(Int, unichar)] = []
        var index = 0, region = 0, statementStart = 0
        var offsets: [Int] = []
        while index < source.length {
            if region < protected.count, index >= protected[region].location {
                index = NSMaxRange(protected[region])
                region += 1
                continue
            }
            let char = source.character(at: index)
            if [40, 91, 123].contains(char) {
                offsets.append(index)
                depths[index] = stack.count
                stack.append((index, char))
            } else if let opener = [41: 40, 93: 91, 125: 123][Int(char)] {
                offsets.append(index)
                if let last = stack.last, Int(last.1) == opener {
                    stack.removeLast()
                    pairs[last.0] = index
                    pairs[index] = last.0
                    depths[index] = depths[last.0]
                } else { unmatched.insert(index) }
            }
            if sql, char == 59, stack.isEmpty {
                statements.append(NSRange(location: statementStart, length: index + 1 - statementStart))
                statementStart = index + 1
            }
            index += 1
        }
        if sql, statementStart < source.length {
            statements.append(NSRange(location: statementStart, length: source.length - statementStart))
        }
        delimiters = offsets
        unmatched.formUnion(stack.map(\.0))
    }

    func isProtected(_ position: Int) -> Bool {
        protected
            .contains {
            position > $0.location && (position < NSMaxRange($0) || (position == NSMaxRange($0) && openEnds.contains(position))) }
    }

    func activePair(at position: Int) -> Set<Int> {
        for candidate in [position, position - 1] {
            if let other = pairs[candidate] { return [candidate, other] }
            if unmatched.contains(candidate) { return [candidate] }
        }
        return []
    }

    func references(at selection: NSRange) -> [NSRange] {
        for ranges in variables.values where ranges.contains(where: {
            selection.length == 0 ? NSLocationInRange(selection.location, $0) || selection.location == NSMaxRange($0)
                : $0 == selection
        }) { return ranges }
        return []
    }
}
