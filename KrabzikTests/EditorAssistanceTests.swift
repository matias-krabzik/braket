import AppKit
@testable import Krabzik
import XCTest

final class EditorAssistanceTests: XCTestCase {
    func testPairsIgnoreStringsCommentsAndTrackDepth() {
        let code = "SELECT (1 + (2)), '(', `)`, /* [ */ @total; -- )\nSELECT [3;"
        let structure = EditorStructure(code, sql: true)
        let source = code as NSString
        let first = source.range(of: "(1").location
        let nested = source.range(of: "(2").location
        XCTAssertEqual(structure.depths[first], 0)
        XCTAssertEqual(structure.depths[nested], 1)
        XCTAssertEqual(structure.pairs[nested], nested + 2)
        XCTAssertEqual(structure.activePair(at: nested), [nested, nested + 2])
        XCTAssertEqual(structure.unmatched, [source.range(of: "[3").location])
        let variable = source.range(of: "@total")
        XCTAssertEqual(structure.references(at: variable), [variable])
    }

    func testMismatchedPairsAndGenericComments() {
        let broken = EditorStructure("([)]", sql: true)
        XCTAssertEqual(broken.unmatched, [0, 2])
        let generic = EditorStructure("// (\nlet x = [\"}\", (1)] /* { */", sql: false)
        XCTAssertTrue(generic.unmatched.isEmpty)
        XCTAssertEqual(generic.pairs.count, 4)
    }

    @MainActor func testAutoCloseWrapSkipDeleteAndUndo() async throws {
        let document = try EditorDocument(url: URL(fileURLWithPath: "/tmp/pairs.sql"), data: Data())
        let surface = EditorSurface(document: document)
        document.editorStorage = surface
        defer { surface.teardown() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = surface
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        let view = surface.textView
        let history = try XCTUnwrap(view.undoManager)
        view.insertText("(", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(view.string, "()")
        XCTAssertEqual(view.selectedRange(), NSRange(location: 1, length: 0))
        try await Task.sleep(for: .milliseconds(40))
        history.undo()
        XCTAssertEqual(view.string, "")
        history.redo()
        XCTAssertEqual(view.string, "()")
        view.setSelectedRange(NSRange(location: 1, length: 0))
        view.deleteBackward(nil)
        XCTAssertEqual(view.string, "")
        view.insertText("()", replacementRange: NSRange(location: 0, length: 0))
        view.setSelectedRange(NSRange(location: 1, length: 0))
        view.insertText(")", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(view.string, "()")
        XCTAssertEqual(view.selectedRange().location, 2)
        view.setSelectedRange(NSRange(location: 0, length: 2))
        view.insertText("[", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(view.string, "[()]")
        XCTAssertEqual(view.selectedRange(), NSRange(location: 1, length: 2))
    }

    @MainActor func testAutoCloseRespectsCommentsStringsReadOnlyAndExplicitReplacement() throws {
        let document = try EditorDocument(url: URL(fileURLWithPath: "/tmp/context.sql"), data: Data("SELECT 'abc'; -- note".utf8))
        let surface = EditorSurface(document: document)
        defer { surface.teardown() }
        let view = surface.textView
        view.setSelectedRange(NSRange(location: 9, length: 0))
        view.insertText("(", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(view.string, "SELECT 'a(bc'; -- note")
        view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
        view.insertText("(", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.string.hasSuffix("note("))
        view.insertText("(", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(view.string.hasPrefix("(SELECT"))
    }

    @MainActor func testFormatterSelectionIsOneUndoAndReadOnlyIsProtected() async throws {
        let code = "select 1;\nselect a,b from customers where id=2;"
        let document = try EditorDocument(url: URL(fileURLWithPath: "/tmp/format.sql"), data: Data(code.utf8))
        let surface = EditorSurface(document: document)
        document.editorStorage = surface
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = surface
        window.makeKeyAndOrderFront(nil)
        defer { surface.teardown()
        window.orderOut(nil) }
        let view = surface.textView
        let selection = (code as NSString).range(of: "select a,b from customers where id=2;")
        view.setSelectedRange(selection)
        view.formatSQL(nil)
        let deadline = ContinuousClock.now + .seconds(4)
        while view.formattingSQL, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(view.formattingSQL)
        XCTAssertTrue(view.string.hasPrefix("select 1;\nSELECT"))
        XCTAssertTrue(view.string.contains("FROM\n"))
        try await Task.sleep(for: .milliseconds(40))
        view.undoManager?.undo()
        XCTAssertEqual(view.string, code)
        view.undoManager?.redo()
        XCTAssertNotEqual(view.string, code)
        view.isEditable = false
        let before = view.string
        view.insertText("(", replacementRange: NSRange(location: NSNotFound, length: 0))
        view.formatSQL(nil)
        XCTAssertEqual(view.string, before)
        XCTAssertFalse(view.formattingSQL)
    }

    func testFormatterPreservesMySQLVariablesStringsAndComments() async throws {
        let code = "set @total=5*2;select @total, 'a;b', `name` from customers where id=1; -- hola\n"
        let formatted = try await SQLFormatterEngine.shared.format(code, options: EditorOptions())
        XCTAssertTrue(formatted.contains("SELECT\n"))
        XCTAssertTrue(formatted.contains("@total"))
        XCTAssertTrue(formatted.contains("'a;b'"))
        XCTAssertTrue(formatted.contains("-- hola"))
        let repeated = try await SQLFormatterEngine.shared.format(formatted, options: EditorOptions())
        XCTAssertEqual(repeated, formatted)
    }

    func testFormatterRejectsBrokenCodeAndCustomDelimiters() async {
        for code in ["SELECT (1", "SELECT 'oops", "DELIMITER $$\nSELECT 1$$"] {
            do {
                _ = try await SQLFormatterEngine.shared.format(code, options: EditorOptions())
                XCTFail("Se aceptó SQL no seguro para formatear")
            } catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
        }
    }
}
