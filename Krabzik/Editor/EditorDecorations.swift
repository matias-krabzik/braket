import AppKit

extension CodeTextView {
    func drawAssistance(in dirty: NSRect) {
        guard let surface = editorSurface, let structure = surface.structure,
              let layout = textLayoutManager, let content = layout.textContentManager,
              let viewport = layout.textViewportLayoutController.viewportRange else { return }
        let options = Theme.settings.editorOptions
        let start = content.offset(from: content.documentRange.location, to: viewport.location)
        let end = content.offset(from: content.documentRange.location, to: viewport.endLocation)
        let source = string as NSString
        func frames(_ range: NSRange, draw: (NSRect) -> Void) {
            guard NSMaxRange(range) <= source.length,
                  let first = content.location(content.documentRange.location, offsetBy: range.location),
                  let last = content.location(first, offsetBy: range.length),
                  let textRange = NSTextRange(location: first, end: last) else { return }
            layout.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, frame, _, _ in
                let box = frame.offsetBy(dx: self.textContainerOrigin.x, dy: self.textContainerOrigin.y)
                if box.intersects(dirty) { draw(box) }
                return true
            }
        }
        let selection = selectedRange()
        let active = structure.activePair(at: selection.location)
        let colors = [EditorPalette.blue, EditorPalette.purple, EditorPalette.orange, EditorPalette.green]
        var low = 0, high = structure.delimiters.count
        while low < high {
            let middle = (low + high) / 2
            if structure.delimiters[middle] < start { low = middle + 1 } else { high = middle }
        }
        for offset in structure.delimiters.dropFirst(low) {
            if offset >= end { break }
            let invalid = structure.unmatched.contains(offset)
            guard options.rainbowBrackets || (options.matchBrackets && (active.contains(offset) || invalid)) else { continue }
            let color = invalid ? NSColor.systemRed : colors[(structure.depths[offset] ?? 0) % colors.count]
            frames(NSRange(location: offset, length: 1)) { box in
                let shape = NSBezierPath(roundedRect: box.insetBy(dx: -1, dy: 0), xRadius: 3, yRadius: 3)
                color.withAlphaComponent(active.contains(offset) ? 0.22 : 0.08).setFill()
                shape.fill()
                if active.contains(offset) || invalid {
                    color.withAlphaComponent(0.8).setStroke()
                    shape.lineWidth = 1
                    shape.stroke()
                } else {
                    color.withAlphaComponent(0.8).setFill()
                    NSRect(x: box.minX, y: box.maxY - 1, width: max(2, box.width), height: 1).fill()
                }
            }
        }
        if options.variableReferences {
            for range in structure.references(at: selection) where NSIntersectionRange(range, NSRange(location: start,
                                                                                                      length: end - start)).length > 0 {
                frames(range) { box in
                    EditorPalette.blue.withAlphaComponent(0.12).setFill()
                    NSBezierPath(roundedRect: box, xRadius: 2, yRadius: 2).fill()
                }
            }
        }
        if options.indentationGuides {
            let width = max(1, options.indentWidth)
            let space = (" " as NSString).size(withAttributes: [.font: font ?? NSFont.monospacedSystemFont(ofSize: 14,
                                                                                                           weight: .regular)]).width
            let currentLine = surface.lines.line(at: selection.location)
            let currentIndent = structure.indents.indices.contains(currentLine) ? structure.indents[currentLine] / width : 0
            let first = surface.lines.line(at: start), last = surface.lines.line(at: end)
            for line in first...last where structure.indents.indices.contains(line) {
                let offset = surface.lines.start(of: line)
                guard offset < source.length else { continue }
                frames(NSRange(location: offset, length: 1)) { box in
                    for level in 0..<(structure.indents[line] / width) {
                        let activeGuide = level == currentIndent - 1
                        EditorPalette.muted.withAlphaComponent(activeGuide ? 0.5 : 0.2).setFill()
                        let x = self.textContainerOrigin.x + CGFloat(level * width) * space
                        NSRect(x: x, y: box.minY, width: 1, height: box.height).fill()
                    }
                }
            }
        }
        if options.activeStatement, surface.document?.language == "SQL",
           let statement = structure.statements.first(where: { NSLocationInRange(selection.location, $0) }) {
            let visible = NSIntersectionRange(statement, NSRange(location: start, length: end - start))
            if visible.length > 0 {
                frames(visible) { box in
                    EditorPalette.blue.withAlphaComponent(0.45).setFill()
                    NSRect(x: self.textContainerOrigin.x - 7, y: box.minY, width: 2, height: box.height).fill()
                }
            }
        }
    }
}
