import AppKit
@testable import Krabzik
import SwiftUI
import XCTest

@MainActor final class SQLGridKeyboardTests: XCTestCase {
    private func column(_ type: String) -> SQLSchemaColumn {
        SQLSchemaColumn(name: "value", type: type, nullable: true, extra: "")
    }
    private func key(_ code: UInt16, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                       windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                                       isARepeat: false, keyCode: code))
    }
    func testIntegerAndDecimalValidationDoesNotLosePrecision() throws {
        XCTAssertEqual(try SQLCellInput.validate("18446744073709551615", column: column("bigint unsigned")), "18446744073709551615")
        for value in ["18446744073709551616", "-1", "1.5", "abc"] {
            XCTAssertThrowsError(try SQLCellInput.validate(value, column: column("bigint unsigned")))
        }
        XCTAssertEqual(try SQLCellInput.validate("-128", column: column("tinyint")), "-128")
        XCTAssertThrowsError(try SQLCellInput.validate("128", column: column("tinyint")))
        XCTAssertEqual(try SQLCellInput.validate("123.45", column: column("decimal(5,2)")), "123.45")
        XCTAssertThrowsError(try SQLCellInput.validate("1234.56", column: column("decimal(5,2)")))
        XCTAssertThrowsError(try SQLCellInput.validate("1.234", column: column("decimal(5,2)")))
        XCTAssertFalse(SQLCellInput.allows("1a", kind: column("int").cellKind))
        XCTAssertFalse(SQLCellInput.allows("12\n", kind: column("int").cellKind))
        XCTAssertTrue(SQLCellInput.allows("-", kind: column("int").cellKind))
        XCTAssertEqual(try SQLCellInput.validate("1e-4", column: column("double")), "1e-4")
        XCTAssertThrowsError(try SQLCellInput.validate("NaN", column: column("double")))
    }
    func testTemporalValidationAndEnumEscapes() throws {
        XCTAssertEqual(try SQLCellInput.validate("2024-02-29", column: column("date")), "2024-02-29")
        XCTAssertThrowsError(try SQLCellInput.validate("2025-02-29", column: column("date")))
        XCTAssertThrowsError(try SQLCellInput.validate("2025-01-01 25:00:00", column: column("datetime")))
        XCTAssertEqual(try SQLCellInput.validate("2026-11-18 12:30:05.123456", column: column("datetime(6)")),
                       "2026-11-18 12:30:05.123456")
        XCTAssertThrowsError(try SQLCellInput.validate("2026-11-18 12:30:05.1234", column: column("datetime(3)")))
        XCTAssertEqual(try SQLCellInput.validate("-838:59:59", column: column("time")), "-838:59:59")
        XCTAssertThrowsError(try SQLCellInput.validate("839:00:00", column: column("time")))
        let metadata = column(#"enum('new','it''s','a\'b','back\\slash','a,b','', '😀')"#)
        XCTAssertEqual(metadata.enumValues, ["new", "it's", "a'b", "back\\slash", "a,b", "", "😀"])
        XCTAssertEqual(try SQLCellInput.validate("a,b", column: metadata), "a,b")
        XCTAssertThrowsError(try SQLCellInput.validate("other", column: metadata))
        XCTAssertThrowsError(try SQLCellInput.validate("abcd", column: column("varchar(3)")))
    }
    func testTextEditorCommandEnterAndReturnAreDifferent() throws {
        let editor = SQLCellEditorController(column: column("text"), value: .text("one"))
        _ = editor.view
        var committed: SQLCellValue?
        editor.onFinish = { committed = $0 }
        editor.textView.setSelectedRange(NSRange(location: 3, length: 0))
        editor.textView.keyDown(with: try key(36, flags: .command))
        XCTAssertEqual(editor.textView.string, "one\n")
        XCTAssertNil(committed)
        editor.textView.insertText("two", replacementRange: editor.textView.selectedRange())
        editor.textView.keyDown(with: try key(36))
        XCTAssertEqual(committed, .text("one\ntwo"))
    }
    func testNumericEditorRejectsPasteAndKeepsInvalidInputOpen() throws {
        let editor = SQLCellEditorController(column: column("tinyint"), value: .text("1"))
        _ = editor.view
        XCTAssertFalse(editor.textView(editor.textView, shouldChangeTextIn: NSRange(location: 0, length: 1), replacementString: "x"))
        editor.textView.string = "999"
        editor.textDidChange(Notification(name: NSText.didChangeNotification))
        var finished = false
        editor.onFinish = { _ in finished = true }
        XCTAssertFalse(editor.confirmValue())
        XCTAssertFalse(finished)
        XCTAssertFalse(editor.errorLabel.isHidden)
        editor.cancelEditing()
        XCTAssertTrue(finished)
    }
    private func find<View: NSView>(_ type: View.Type, in root: NSView) -> [View] {
        (root as? View).map { [$0] } ?? root.subviews.flatMap { find(type, in: $0) }
    }
    func testDateSelectorsServerNowAndOriginalFractionalPrecision() async throws {
        let expected = ["date": "2009-02-14", "datetime(6)": "2009-02-14 08:31:30.123456",
                        "timestamp(3)": "2009-02-14 08:31:30.123", "time(3)": "08:31:30.123", "year": "2009"]
        for type in expected.keys.sorted() {
            let metadata = column(type)
            let editor = SQLCellEditorController(column: metadata, value: .null)
            let value = try XCTUnwrap(expected[type])
            editor.serverNow = { received in
                XCTAssertEqual(received, metadata)
                return value
            }
            let root = editor.view
            XCTAssertGreaterThanOrEqual(editor.preferredContentSize.height, 27)
            let calendar = editor.calendarContent
            let picker = try XCTUnwrap(find(NSDatePicker.self, in: calendar).first)
            XCTAssertLessThanOrEqual(picker.fittingSize.width, calendar.bounds.width)
            let now = try XCTUnwrap(find(NSButton.self, in: root).first { $0.title == "Ahora" })
            var committed: SQLCellValue?
            editor.onFinish = { committed = $0 }
            now.performClick(nil)
            let deadline = ContinuousClock.now + .seconds(2)
            while editor.loadingNow, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(editor.textView.string, value)
            XCTAssertTrue(editor.confirmValue(), type)
            XCTAssertEqual(committed, .text(value))
        }
        let exact = "2026-11-18 12:30:00.123456"
        let editor = SQLCellEditorController(column: column("datetime(6)"), value: .text(exact))
        _ = editor.view
        var committed: SQLCellValue?
        editor.onFinish = { committed = $0 }
        editor.confirmEditing()
        XCTAssertEqual(committed, .text(exact), "Abrir y confirmar no debe redondear microsegundos")
    }
    func testServerNowFailurePreservesValueWithoutLocalFallback() async throws {
        let original = "2020-01-02 03:04:05"
        let editor = SQLCellEditorController(column: column("datetime"), value: .text(original))
        _ = editor.view
        editor.serverNow = { _ in throw DatabaseFailure("Servidor no disponible") }
        editor.useNow()
        let deadline = ContinuousClock.now + .seconds(2)
        while editor.loadingNow, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(editor.textView.string, original)
        XCTAssertFalse(editor.errorLabel.isHidden)
        XCTAssertEqual(editor.errorLabel.stringValue, "Servidor no disponible")
    }
    func testEnumUsesOnlySchemaValuesAndNullIsExplicit() throws {
        let metadata = column("enum('new','in progress','done')")
        let editor = SQLCellEditorController(column: metadata, value: .text("new"))
        let root = editor.view
        let choices = try XCTUnwrap(find(NSPopUpButton.self, in: root).first)
        XCTAssertEqual(choices.itemTitles, ["new", "in progress", "done"])
        var committed: SQLCellValue?
        editor.onFinish = { committed = $0 }
        choices.selectItem(at: 1)
        XCTAssertTrue(choices.sendAction(choices.action, to: choices.target))
        XCTAssertEqual(committed, .text("in progress"))
        let nullable = SQLCellEditorController(column: metadata, value: .null)
        _ = nullable.view
        nullable.onFinish = { committed = $0 }
        nullable.confirmEditing()
        XCTAssertEqual(committed, .null)
    }

    func testArrowsEnterCommitCancelAndInsertedRowMapping() async throws {
        let columns = [SQLSchemaColumn(name: "id", type: "int", nullable: false, extra: "auto_increment"), column("text")]
        let schema = SQLSchemaTable(database: "qa", name: "items", kind: "BASE TABLE", engine: "InnoDB", columns: columns,
                                    uniqueKeys: [["id"]], primaryKey: ["id"])
        var result = SQLResult(statement: 1, line: 1)
        result.sql = "SELECT * FROM items"
        result.columns = columns.map(\.name)
        result.origins = columns.map { SQLColumnOrigin(database: "qa", table: "items", column: $0.name) }
        result.rows = [["1", "one"], ["2", "two"]]
        let draft = SQLResultDraft(result: result)
        draft.configure(schema)
        let host = NSHostingView(rootView: SQLResultGrid(draft: draft, scale: 1, theme: .graphite))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { SQLCellEditorController.active?.cancelEditing()
        window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(150))
        func find(_ view: NSView) -> SQLGridTable? {
            if let table = view as? SQLGridTable { return table }
            return view.subviews.lazy.compactMap { find($0) }.first
        }
        let table = try XCTUnwrap(find(host))
        table.keyDown(with: try key(125))
        XCTAssertEqual(draft.selectedCell, SQLCell(row: 0, column: 0))
        table.keyDown(with: try key(124))
        table.keyDown(with: try key(125))
        XCTAssertEqual(draft.selectedCell, SQLCell(row: 1, column: 1))
        table.keyDown(with: try key(36))
        XCTAssertTrue(draft.isEditingCell)
        let editor = try XCTUnwrap(SQLCellEditorController.active)
        XCTAssertTrue(editor.view.isDescendant(of: table), "El editor debe estar dentro de la celda")
        XCTAssertNil(editor.popover, "Editar texto no debe abrir un panel flotante")
        editor.textView.insertText("after", replacementRange: NSRange(location: 0, length: 3))
        editor.textView.setSelectedRange(NSRange(location: 5, length: 0))
        XCTAssertTrue(SQLGridTable.reviewFocusedGrid(), "⌘Enter debe llegar al editor de la celda")
        editor.textView.insertText("line", replacementRange: editor.textView.selectedRange())
        try await Task.sleep(for: .milliseconds(60))
        table.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(table.rect(ofRow: 1).height, 27, "La fila debe crecer para mostrar el salto de línea")
        XCTAssertGreaterThan(editor.view.bounds.height, 27, "El editor debe crecer dentro de la celda")
        XCTAssertFalse(draft.showingReview, "⌘Enter al editar no debe abrir la revisión")
        editor.textView.keyDown(with: try key(36))
        XCTAssertFalse(draft.isEditingCell)
        XCTAssertEqual(draft.value(row: 1, column: 1), .text("after\nline"))
        table.keyDown(with: try key(36))
        SQLCellEditorController.active?.textView.keyDown(with: try key(53))
        XCTAssertFalse(draft.isEditingCell)
        draft.addRow()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(draft.selectedCell, SQLCell(row: 2, column: 0))
        table.keyDown(with: try key(124))
        table.keyDown(with: try key(125))
        XCTAssertEqual(draft.selectedCell, SQLCell(row: 0, column: 1))
        table.keyDown(with: try key(126))
        XCTAssertEqual(draft.selectedCell, SQLCell(row: 2, column: 1))
        table.keyDown(with: try key(48, flags: .shift))
        XCTAssertEqual(draft.selectedCell, SQLCell(row: 2, column: 0))
    }
}
