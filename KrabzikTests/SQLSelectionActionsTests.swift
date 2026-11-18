import AppKit
@testable import Krabzik
import XCTest

// El host XCTest no activa sus ventanas: el foco local sigue siendo el NSTextView real.
private final class SelectionTestWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}

final class SQLSelectionActionsTests: XCTestCase {
    func testPartialSelectionExpandsLinesAndPreservesUnicodeIndentAndEndings() throws {
        let text = "  SELECT '😀';\r\n\tSELECT 2;\r\nSELECT 3;"
        let range = (text as NSString).range(of: "😀';\r\n\tSELECT")
        let edit = try XCTUnwrap(SQLCommentToggle.edit(in: text, selection: range))
        XCTAssertEqual(edit.replacement, "  -- SELECT '😀';\r\n\t-- SELECT 2;\r\n")
        let changed = (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
        let undo = try XCTUnwrap(SQLCommentToggle.edit(in: changed, selection: edit.selection))
        XCTAssertTrue(undo.uncommenting)
        XCTAssertEqual((changed as NSString).replacingCharacters(in: undo.range, with: undo.replacement), text)
    }

    func testCommentDetectionAndLineBoundary() throws {
        for (text, expected, uncomment) in [
            ("-- SELECT 1;\n# SELECT 2;", "SELECT 1;\nSELECT 2;", true),
            ("--2\nSELECT 1;", "-- --2\n-- SELECT 1;", false),
            ("/* SELECT 1; */", " SELECT 1; ", true),
            ("/*! SELECT 1; */", "-- /*! SELECT 1; */", false),
            ("-- SELECT 1;\nSELECT 2;", "-- -- SELECT 1;\n-- SELECT 2;", false)
        ] {
            let edit = try XCTUnwrap(SQLCommentToggle.edit(in: text, selection: NSRange(location: 0, length: text.utf16.count)))
            XCTAssertEqual(edit.replacement, expected)
            XCTAssertEqual(edit.uncommenting, uncomment)
        }
        let edit = try XCTUnwrap(SQLCommentToggle.edit(in: "one\ntwo", selection: NSRange(location: 1, length: 3)))
        XCTAssertEqual(edit.replacement, "-- one\n")
        XCTAssertNil(SQLCommentToggle.edit(in: " \n", selection: NSRange(location: 0, length: 2)))
        XCTAssertNil(SQLCommentToggle.edit(in: "x", selection: NSRange(location: NSNotFound, length: 1)))
    }

    @MainActor func testActionsKeepSelectionAndNativeUndoAndRejectStaleTarget() throws {
        let original = "SELECT 1;\nSELECT 2;"
        let document = try EditorDocument(url: URL(fileURLWithPath: "/tmp/selection-actions.sql"), data: Data(original.utf8))
        let surface = EditorSurface(document: document)
        document.editorStorage = surface
        let window = SelectionTestWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 400),
                                         styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = surface
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(surface.textView)
        defer { surface.teardown()
        window.orderOut(nil) }
        surface.layoutSubtreeIfNeeded()
        let range = NSRange(location: 0, length: 9)
        surface.textView.setSelectedRange(range)
        let actions = surface.selectionActions
        var runs = 0
        actions.execute = { runs += 1
        XCTAssertEqual(document.selectedRange, range) }
        actions.canExecute = true
        XCTAssertEqual(document.language, "SQL")
        XCTAssertTrue(window.isKeyWindow)
        XCTAssertTrue(window.firstResponder === surface.textView)
        XCTAssertFalse(surface.textView.hasMarkedText())
        XCTAssertFalse(document.search.visible)
        XCTAssertNotNil(SQLCommentToggle.edit(in: surface.textView.string, selection: surface.textView.selectedRange()))
        actions.refresh()
        XCTAssertTrue(actions.visible)
        actions.run()
        XCTAssertEqual(runs, 1)
        XCTAssertEqual(surface.textView.selectedRange(), range)
        actions.refresh()
        actions.toggleComment()
        XCTAssertEqual(document.text, "-- SELECT 1;\nSELECT 2;")
        let history = try XCTUnwrap(surface.textView.undoManager)
        while history.groupingLevel > 0 { history.endUndoGrouping() }
        history.undo()
        XCTAssertEqual(document.text, original)
        history.redo()
        XCTAssertEqual(document.text, "-- SELECT 1;\nSELECT 2;")
        surface.textView.setSelectedRange(NSRange(location: 0, length: 12))
        actions.refresh()
        XCTAssertEqual(actions.comment.toolTip, "Descomentar líneas seleccionadas")
        // Simula el nuevo evento de usuario después de cerrar manualmente el grupo para Undo.
        history.beginUndoGrouping()
        actions.toggleComment()
        while history.groupingLevel > 0 { history.endUndoGrouping() }
        XCTAssertEqual(document.text, original)
        actions.refresh()
        surface.textView.setSelectedRange(NSRange(location: 0, length: 0))
        actions.run()
        XCTAssertEqual(runs, 1)
        actions.refresh()
        XCTAssertFalse(actions.visible)
        surface.textView.setSelectedRange(range)
        actions.readOnly = true
        actions.refresh()
        XCTAssertFalse(actions.visible)
        actions.invalidate()
        XCTAssertNil(actions.execute)
    }
}
