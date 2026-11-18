import AppKit

extension CodeTextView {
    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        guard isEditable else { return }
        let input = (insertString as? String) ?? (insertString as? NSAttributedString)?.string ?? ""
        let selection = selectedRange()
        guard isEditable, Theme.settings.editorOptions.autoClose, !hasMarkedText(), input.utf16.count == 1,
              replacementRange.location == NSNotFound else {
            super.insertText(insertString, replacementRange: replacementRange)
            return
        }
        let source = string as NSString
        let position = selection.location
        let char = Array(input.utf16)[0]
        let closes: [unichar: unichar] = [40: 41, 91: 93, 123: 125, 39: 39, 34: 34, 96: 96]
        let quote = [39, 34, 96].contains(char)
        let structure = EditorStructure(string, sql: editorSurface?.document?.language == "SQL")
        var slashes = 0, previous = position
        while previous > 0, source.character(at: previous - 1) == 92 { slashes += 1
        previous -= 1 }
        let escaped = slashes % 2 == 1
        let closingQuote = structure.protected.contains {
            NSMaxRange($0) == position + 1 && $0.length > 1 && source.character(at: $0.location) == char
        }
        if selection.length == 0, position < source.length, source.character(at: position) == char,
           [41, 93, 125, 39, 34, 96].contains(char), !escaped,
           quote ? closingQuote : !structure.isProtected(position) {
            setSelectedRange(NSRange(location: position + 1, length: 0))
            return
        }
        guard let closing = closes[char], !escaped,
              selection.length > 0 || !structure.isProtected(position) else {
            super.insertText(insertString, replacementRange: replacementRange)
            return
        }
        // No completar comillas en medio de un identificador o una palabra.
        if quote, selection.length == 0, position > 0 {
            let previous = source.character(at: position - 1)
            if CharacterSet.alphanumerics.contains(UnicodeScalar(previous) ?? " ") || previous == 95 {
                super.insertText(insertString, replacementRange: replacementRange)
                return
            }
        }
        let selected = source.substring(with: selection)
        let end = String(utf16CodeUnits: [closing], count: 1)
        breakUndoCoalescing()
        super.insertText(input + selected + end, replacementRange: selection)
        setSelectedRange(NSRange(location: position + 1, length: selection.length))
        breakUndoCoalescing()
    }

    override func deleteBackward(_ sender: Any?) {
        guard isEditable else { return }
        let selection = selectedRange()
        let source = string as NSString
        let position = selection.location
        if isEditable, Theme.settings.editorOptions.autoClose, !hasMarkedText(), selection.length == 0,
           position > 0, position < source.length,
           let closing = [40: 41, 91: 93, 123: 125, 39: 39, 34: 34, 96: 96][Int(source.character(at: position - 1))],
           Int(source.character(at: position)) == closing {
            let structure = EditorStructure(string, sql: editorSurface?.document?.language == "SQL")
            let isEmptyQuote = structure.protected.contains { $0 == NSRange(location: position - 1, length: 2) }
            if !structure.isProtected(position) || isEmptyQuote {
                breakUndoCoalescing()
                super.insertText("", replacementRange: NSRange(location: position - 1, length: 2))
                breakUndoCoalescing()
                return
            }
        }
        super.deleteBackward(sender)
    }
}
