import AppKit
import SwiftUI

struct ConsoleView: NSViewRepresentable {
    let run: ProjectRun

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let text = NSTextView(usingTextLayoutManager: true)
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.backgroundColor = EditorPalette.background
        text.textColor = EditorPalette.text
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.textContainerInset = NSSize(width: 16, height: 12)
        text.autoresizingMask = [.width]
        text.isVerticallyResizable = true
        text.textContainer?.widthTracksTextView = true
        text.setAccessibilityLabel("Salida del proceso")
        scroll.documentView = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let _ = run.revision
        guard let text = scroll.documentView as? NSTextView else { return }
        let wasAtBottom = scroll.contentView.bounds.maxY >= text.bounds.height - 35
        let newOutput = run.output
        let oldOutput = text.string
        if newOutput.hasPrefix(oldOutput), let storage = text.textStorage {
            let addition = String(newOutput.dropFirst(oldOutput.count))
            storage.append(NSAttributedString(string: addition, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: EditorPalette.text]))
        } else { text.string = newOutput }
        if wasAtBottom { text.scrollToEndOfDocument(nil) }
    }
}
