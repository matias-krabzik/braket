import AppKit
@testable import Krabzik
import XCTest

final class EditorSearchTests: XCTestCase {
    func testLiteralWholeWordAndUnicodeRanges() throws {
        let text = "niño NIÑO niño_extra 😀 niño"
        var options = EditorSearchOptions()
        options.wholeWord = true
        let matches = try EditorSearchMatcher.matches(text, query: "niño", options: options)
        XCTAssertEqual(matches.count, 3)
        XCTAssertEqual(matches.map { (text as NSString).substring(with: $0.range) }, ["niño", "NIÑO", "niño"])
        options.caseSensitive = true
        XCTAssertEqual(try EditorSearchMatcher.matches(text, query: "niño", options: options).count, 2)
        XCTAssertEqual(try EditorSearchMatcher.matches("a.b axb", query: "a.b", options: .init()).count, 1)
    }

    func testRegexReplacementUsesCaptureGroupsAndLiteralReplacementPreservesDollar() throws {
        let text = "customer_12"
        var options = EditorSearchOptions()
        options.regularExpression = true
        let match = try XCTUnwrap(EditorSearchMatcher.matches(text, query: #"customer_(\d+)"#, options: options).first)
        XCTAssertEqual(try EditorSearchMatcher.replacement("client_$1", match: match, source: text,
                                                           query: #"customer_(\d+)"#, options: options), "client_12")
        XCTAssertEqual(try EditorSearchMatcher.replacement("$1", match: match, source: text,
                                                           query: "customer_12", options: .init()), "$1")
        XCTAssertThrowsError(try EditorSearchMatcher.matches(text, query: "[", options: options))
    }

    func testZeroWidthMatchesAdvanceWithoutSplittingUnicode() throws {
        var options = EditorSearchOptions()
        options.regularExpression = true
        let text = "😀a"
        let matches = try EditorSearchMatcher.matches(text, query: "(?=a)|$", options: options)
        XCTAssertEqual(matches.map(\.range), [NSRange(location: 2, length: 0), NSRange(location: 3, length: 0)])
    }

    @MainActor private func settle(_ search: EditorSearch) async throws {
        let deadline = ContinuousClock.now + .seconds(4)
        while search.searching, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(search.searching)
        XCTAssertNil(search.error)
    }

    @MainActor func testReplaceAllIsOneUndoOperationAndClearsSetNotes() async throws {
        let original = "SET @limite = 10;\nSELECT @limite;\n"
        let document = try EditorDocument(url: URL(fileURLWithPath: "/tmp/find-test.sql"), data: Data(original.utf8))
        let surface = EditorSurface(document: document)
        document.editorStorage = surface
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = surface
        window.makeKeyAndOrderFront(nil)
        defer { document.search.hide()
        surface.teardown()
        window.orderOut(nil) }
        let history = try XCTUnwrap(surface.textView.undoManager)
        history.groupsByEvent = true
        var result = SQLResult(statement: 1, line: 1)
        result.connection = DatabaseConnection()
        result.sql = "SET @limite = 10"
        result.setValues = [SQLSetValue(name: "@limite", value: "10")]
        document.setVariableNote(result, revision: document.queryMarkerRevision)
        let search = document.search
        search.query = "limite"
        search.replacement = "maximo"
        search.show(in: document, replace: true)
        try await settle(search)
        XCTAssertEqual(search.matches.count, 2)
        search.replace(all: true, allowed: true)
        XCTAssertEqual(document.text, original.replacingOccurrences(of: "limite", with: "maximo"))
        XCTAssertTrue(document.setNotes.isEmpty)
        XCTAssertTrue(document.isDirty)
        surface.textView.breakUndoCoalescing()
        while history.groupingLevel > 0 { history.endUndoGrouping() }
        history.undo()
        XCTAssertEqual(document.text, original)
        history.redo()
        XCTAssertEqual(document.text, original.replacingOccurrences(of: "limite", with: "maximo"))
    }

    @MainActor func testReadOnlyAndEditsDuringSearchCannotReplaceStaleRanges() async throws {
        let document = try EditorDocument(url: URL(fileURLWithPath: "/tmp/find-stale.sql"), data: Data("uno uno".utf8))
        let surface = EditorSurface(document: document)
        document.editorStorage = surface
        defer { document.search.hide()
        surface.teardown() }
        let search = document.search
        search.query = "uno"
        search.replacement = "dos"
        search.show(in: document, replace: true)
        try await settle(search)
        search.replace(all: true, allowed: false)
        XCTAssertEqual(document.text, "uno uno")
        surface.textView.insertText("prefijo ", replacementRange: NSRange(location: 0, length: 0))
        search.replace(all: true, allowed: true)
        XCTAssertEqual(document.text, "prefijo uno uno")
        try await settle(search)
        XCTAssertEqual(search.matches.count, 2)
        search.navigate()
        XCTAssertEqual(search.currentIndex, 1)
        search.hide()
        XCTAssertEqual(search.query, "uno")
        XCTAssertFalse(search.visible)
    }
}
